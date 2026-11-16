import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'apple_photos.dart';
import 'model.dart';

final _archiveName = RegExp(r'^([0-9a-f]{64})\.photoslibrary\.tar\.gz$');

Future<void> requirePhotosClosed() async {
  final result = await Process.run('/usr/bin/pgrep', ['-x', 'Photos']);
  if (result.exitCode == 0) {
    throw StateError('Quit Apple Photos before creating a library archive.');
  }
  if (result.exitCode != 1) {
    throw StateError('Haven could not check whether Apple Photos is open.');
  }
}

// The application may be closed while system background processes still
// update the package. Compare metadata for every entry around the archive.
Future<String> _fingerprint(Directory library) async {
  final rows = <String>[(await library.stat()).changed.toIso8601String()];
  await for (final entity in library.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! Directory && entity is! File) {
      throw const FormatException(
        'The library contains a link or unsupported file.',
      );
    }
    final stat = await entity.stat();
    if (stat.type == FileSystemEntityType.notFound) {
      throw StateError('The Apple Photos library changed during archival.');
    }
    rows.add(
      jsonEncode([
        p.relative(entity.path, from: library.path),
        stat.type.toString(),
        stat.size,
        stat.mode,
        stat.modified.microsecondsSinceEpoch,
        stat.changed.microsecondsSinceEpoch,
      ]),
    );
  }
  rows.sort();
  return sha256.convert(utf8.encode(rows.join('\n'))).toString();
}

Future<String> _digest(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> _tool(String command, List<String> args, String failure) async {
  final result = await Process.run(command, args);
  if (result.exitCode != 0) throw StateError(failure);
}

Future<ApplePhotosArchiveResult> archiveApplePhotos(
  String path,
  Directory stagingRoot,
  Future<File> Function(String relative) destination,
) async {
  await requirePhotosClosed();
  final source = Directory(await Directory(path).resolveSymbolicLinks());
  final before = await _fingerprint(source);
  final library = await ApplePhotosLibrary.read(path, verifyIntegrity: true);
  var missing = 0;
  for (final asset in library.assets) {
    if (await library.original(asset) == null) missing++;
  }
  final staging = await stagingRoot.createTemp('photos-archive-');
  try {
    final archive = File(p.join(staging.path, 'archive.tar.gz'));
    await _tool('/usr/bin/tar', [
      '-czf',
      archive.path,
      '--mac-metadata',
      '--format',
      'pax',
      '--options',
      'gzip:compression-level=1',
      '-C',
      source.parent.path,
      '--',
      p.basename(source.path),
    ], 'Haven could not create the Photos archive.');
    await requirePhotosClosed();
    if (await _fingerprint(source) != before) {
      throw StateError(
        'The Apple Photos library changed during archival. Try again.',
      );
    }
    await _tool('/usr/bin/gzip', [
      '-t',
      archive.path,
    ], 'The Photos archive failed verification.');
    final hash = await _digest(archive);
    final target = await destination(
      '${library.id}/$hash.photoslibrary.tar.gz',
    );
    if (await target.exists()) {
      if (await _digest(target) != hash) {
        throw StateError(
          'An existing Photos archive failed checksum verification.',
        );
      }
    } else {
      await archive.rename(target.path);
    }
    final stat = await target.stat();
    return ApplePhotosArchiveResult(
      LocalEntry(
        ref: target.path,
        name: p.basename(target.path),
        mime: 'application/gzip',
        size: stat.size,
        modified: stat.modified.microsecondsSinceEpoch,
        captured: stat.modified.microsecondsSinceEpoch,
      ),
      missing,
    );
  } finally {
    await staging.delete(recursive: true);
  }
}

/// Restore into a private sibling directory, then expose the package only
/// after the archive and the extracted database both pass verification.
Future<String> restoreApplePhotosArchive(
  File archive,
  Directory destination,
) async {
  final expected = _archiveName.firstMatch(p.basename(archive.path))?[1];
  if (expected == null) {
    throw const FormatException(
      'Choose a verified .photoslibrary.tar.gz created by Haven.',
    );
  }
  final stage = await destination.createTemp('.haven-photos-restore-');
  try {
    // Verify the same local bytes we extract, even if the NAS is shared with
    // another process that can replace the archive while we are reading it.
    final local = await archive.copy(p.join(stage.path, 'archive.tar.gz'));
    if (await _digest(local) != expected) {
      throw StateError('The Photos archive failed checksum verification.');
    }
    final unpacked = await Directory(p.join(stage.path, 'unpacked')).create();
    await _tool('/usr/bin/tar', [
      '-xf',
      local.path,
      '--mac-metadata',
      '--safe-writes',
      '-C',
      unpacked.path,
    ], 'Haven could not extract the Photos archive safely.');
    final contents = await unpacked.list(followLinks: false).toList();
    if (contents.length != 1 ||
        contents.single is! Directory ||
        p.extension(contents.single.path).toLowerCase() != '.photoslibrary') {
      throw const FormatException(
        'The archive does not contain a single Photos library.',
      );
    }
    final library = contents.single as Directory;
    await ApplePhotosLibrary.read(library.path, verifyIntegrity: true);
    final dated = DateTime.now().toUtc().microsecondsSinceEpoch;
    final name = p.basenameWithoutExtension(library.path);
    final target = p.join(
      destination.path,
      '$name (restored $dated).photoslibrary',
    );
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError(
        'A Photos library already exists at the restore destination.',
      );
    }
    return (await library.rename(target)).path;
  } finally {
    await stage.delete(recursive: true);
  }
}
