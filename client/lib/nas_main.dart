import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'api.dart';
import 'controller.dart';
import 'local_io.dart';
import 'model.dart';

/// A TrueNAS sink uses the native peer engine independently of the desktop UI.
Future<void> main() => runNas();

Future<void> runNas({bool smokeSource = false}) async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SizedBox.shrink());
  try {
    await _run(smokeSource);
  } catch (error) {
    stderr.writeln('Haven sink stopped: $error');
    exit(1);
  }
}

Future<void> _run(bool smokeSource) async {
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
  final controller = HavenController(api: session, local: disk);
  final approval = File(p.join(state.path, 'approval-url'));
  final configuredName = env['HAVEN_DEVICE_NAME']?.trim() ?? '';
  final name = configuredName.isEmpty ? 'TrueNAS Sink' : configuredName;
  if (smokeSource) {
    // The native integration test uses an ordinary, temporary source device.
    await session.restore();
    controller.config = await session.request('GET', '/api/config');
    if (controller.config['dev'] != true) {
      throw StateError('The smoke-test source requires a development backend.');
    }
    await controller.connect();
    controller.name = name;
    await controller.configure(['viewer', 'sink', 'source']);
    return;
  }

  var waitingForBackend = false;
  var credentialRejected = false;
  while (true) {
    try {
      await session.restore();
      controller.config = await session.request('GET', '/api/config');
      if (controller.config['unattended_sinks'] != true) {
        if (!waitingForBackend) {
          stdout.writeln(
            'Waiting for a Haven server that supports unattended sinks.',
          );
        }
        waitingForBackend = true;
      } else {
        waitingForBackend = false;
        if (!session.hasSinkCredential) {
          // A legacy login may be expired. Leave its stored token alone until
          // the account owner has explicitly approved the new credential.
          session.token = null;
          await session.pair(name, approval);
        }
        await session.saveNativeLogin(null);
        if (await approval.exists()) await approval.delete();
        await controller.connect(requireUnattendedSink: true);
        credentialRejected = false;
        stdout.writeln('Haven sink connected. Waiting for verified transfers.');
        while (controller.ready) {
          await Future<void>.delayed(const Duration(seconds: 5));
        }
      }
    } on ApiError catch (error) {
      if (error.status == 401 && session.hasSinkCredential) {
        // Do not silently enroll again after the owner revokes this device.
        if (!credentialRejected) {
          stdout.writeln(
            'Haven rejected this sink credential. Clear the credential in the private state dataset to pair again.',
          );
        }
        credentialRejected = true;
      } else if (error.status >= 500 || [408, 429].contains(error.status)) {
        stderr.writeln(
          'Haven is temporarily unavailable (HTTP ${error.status}).',
        );
      } else {
        rethrow;
      }
    } on http.ClientException {
      stderr.writeln('Haven is temporarily unreachable.');
    } on TimeoutException {
      stderr.writeln('Haven did not respond in time.');
    }
    await Future<void>.delayed(Duration(seconds: credentialRejected ? 30 : 10));
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
  bool get hasSinkCredential => token?.startsWith('haven_sink_') == true;

  Future<void> pair(String name, File approval) async {
    while (true) {
      var login = await restoreNativeLogin();
      if (login == null || login['unattended'] != true) {
        if (await approval.exists()) await approval.delete();
        final random = Random.secure();
        final verifier = base64UrlEncode(
          List<int>.generate(32, (_) => random.nextInt(256)),
        ).replaceAll('=', '');
        final challenge = base64UrlEncode(
          sha256.convert(utf8.encode(verifier)).bytes,
        ).replaceAll('=', '');
        final request =
            await this.request('POST', '/api/auth/native/start', {
                  'challenge': challenge,
                  'platform': 'linux',
                  'sink_name': name,
                })
                as Json;
        final uri = Uri.parse(request['approval_url'] as String);
        if (uri.origin != base || uri.userInfo.isNotEmpty) {
          throw StateError('Haven returned an invalid approval URL.');
        }
        login = {
          'id': request['id'],
          'verifier': verifier,
          'approval_url': uri.toString(),
          'expires': DateTime.now()
              .add(const Duration(minutes: 10))
              .millisecondsSinceEpoch,
          'unattended': true,
        };
        await saveNativeLogin(login);
        stdout.writeln(
          'Haven sink requires one-time approval. Read /state/approval-url from the container shell.',
        );
      }
      await _writePrivate(approval, "${login['approval_url']}\n");
      while (DateTime.now().millisecondsSinceEpoch < login['expires']) {
        try {
          final result =
              await request('POST', '/api/auth/native/poll', {
                    'id': login['id'],
                    'verifier': login['verifier'],
                  })
                  as Json;
          final credential = result['token'];
          if (credential is String && credential.startsWith('haven_sink_')) {
            await setToken(credential);
            return;
          }
          if (result['status'] != 'pending') {
            throw StateError('Haven did not issue a sink credential.');
          }
        } on ApiError catch (error) {
          if (error.status == 404 || error.status == 409) break;
          rethrow;
        }
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      await saveNativeLogin(null);
    }
  }

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
