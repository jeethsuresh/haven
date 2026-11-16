import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import 'api.dart';
import 'controller.dart';
import 'local_io.dart';

/// A TrueNAS sink uses the native peer engine independently of the desktop UI.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  try {
    await _run();
  } catch (error) {
    stderr.writeln('Haven sink stopped: $error');
    exit(1);
  }
}

Future<void> _run() async {
  final env = Platform.environment;
  final url = Uri.parse(
    env['HAVEN_BACKEND_URL'] ?? 'https://haven.gravitas.cool',
  );
  if (url.scheme != 'https' ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty ||
      url.query.isNotEmpty ||
      url.fragment.isNotEmpty ||
      (url.path.isNotEmpty && url.path != '/')) {
    throw const FormatException('HAVEN_BACKEND_URL must be an HTTPS origin.');
  }
  final state = Directory('/state');
  final repository = Directory('/repository');
  final media = env['HAVEN_USE_MEDIA_MOUNT'] == '1'
      ? Directory('/media')
      : null;
  for (final dir in [state, repository, ?media]) {
    // Require an existing mount and exercise permissions before connecting.
    if (!await dir.exists()) {
      throw StateError('Missing TrueNAS host-path mount at ${dir.path}.');
    }
    final check = await dir.createTemp('.haven-mount-test-');
    await check.delete();
  }
  final session = _NasSessionApi(url.origin, state);
  final disk = _NasRepository(repository, media);
  final approval = File('/state/approval-url');
  final controller = HavenController(
    api: session,
    local: disk,
    brokerAuthorize: (_, _, _) async => null,
    openNativeBrowser: (uri) async {
      if (uri.origin != url.origin) return false;
      await _writePrivate(approval, '$uri\n');
      stdout.writeln(
        'Haven sink requires approval. Read /state/approval-url from the container shell.',
      );
      return true;
    },
  );
  while (true) {
    try {
      // Each approval URL is short-lived. Restarting starts a new request
      // with a visible URL if the old approval had not yet been redeemed.
      await session.saveNativeLogin(null);
      if (await approval.exists()) await approval.delete();
      await controller.initialize();
      if (!controller.ready) await controller.signIn(browser: true);
      if (controller.ready) {
        if (await approval.exists()) await approval.delete();
        final name = env['HAVEN_DEVICE_NAME']?.trim();
        controller.name = name == null || name.isEmpty ? 'TrueNAS Sink' : name;
        await controller.configure(['viewer', 'sink']);
        stdout.writeln('Haven sink connected. Waiting for verified transfers.');
        while (controller.ready) {
          await Future<void>.delayed(const Duration(seconds: 5));
        }
        stdout.writeln('Haven sink session ended.');
      }
    } on ApiError catch (error) {
      if (error.status == 403) rethrow;
      stderr.writeln(
        'Haven is temporarily unavailable (HTTP ${error.status}).',
      );
    }
    await Future<void>.delayed(const Duration(seconds: 10));
  }
}

class _NasRepository extends DiskRepository {
  _NasRepository(this.repository, this.media);
  final Directory repository;
  final Directory? media;

  @override
  Future<void> load(String account) async {
    await super.load(account);
    for (final folder in [repository, ?media]) {
      final owner = File(p.join(folder.path, '.haven-account'));
      final kind = await FileSystemEntity.type(owner.path, followLinks: false);
      if (kind == FileSystemEntityType.notFound) {
        // The container holds a filesystem lock on each selected dataset.
        await _writePrivate(owner, '$account\n');
      } else if (kind != FileSystemEntityType.file ||
          (await owner.readAsString()).trim() != account) {
        throw StateError(
          'This storage folder is assigned to another Haven account.',
        );
      }
    }
    root = repository.path;
    mediaRoot = media?.path ?? '';
  }
}

class _NasSessionApi extends HavenApi {
  _NasSessionApi(String base, this.state) : super(base: base);
  final Directory state;
  File _secret(String key) =>
      File(p.join(state.path, '.session-${sha256.convert(utf8.encode(key))}'));
  @override
  Future<String?> readLocalSecret(String key) async {
    final file = _secret(key);
    final kind = await FileSystemEntity.type(file.path, followLinks: false);
    if (kind == FileSystemEntityType.notFound) return null;
    if (kind != FileSystemEntityType.file) {
      throw StateError('Invalid sink session file.');
    }
    return file.readAsString();
  }

  @override
  Future<void> writeLocalSecret(String key, String? value) async {
    final file = _secret(key);
    if (value == null) {
      if (await file.exists()) await file.delete();
    } else {
      await _writePrivate(file, value);
    }
  }
}

Future<void> _writePrivate(File target, String value) async {
  final staging = await target.parent.createTemp('.haven-secret-');
  try {
    final file = await File(p.join(staging.path, 'value')).create();
    final mode = await Process.run('/bin/chmod', ['600', file.path]);
    if (mode.exitCode != 0) {
      throw StateError('Could not secure Haven sink state.');
    }
    await file.writeAsString(value, flush: true);
    await file.rename(target.path);
  } finally {
    await staging.delete(recursive: true);
  }
}
