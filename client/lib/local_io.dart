import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'apple_photos.dart';
import 'apple_photos_archive.dart';
import 'model.dart';

LocalRepository createRepository() => DiskRepository();

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

class DiskRepository extends LocalRepository {
  static const channel = MethodChannel('cool.gravitas.haven/media');
  static const _photosImport = MethodChannel(
    'cool.gravitas.haven/photos_import',
  );
  late File _index;
  Future<void> _writes = Future.value();
  @override
  Future<void> load(String account) async {
    records.clear();
    root = '';
    mediaRoot = '';
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'haven'));
    await dir.create(recursive: true);
    _index = File(p.join(dir.path, '$account.json'));
    if (await _index.exists()) {
      final j = jsonDecode(await _index.readAsString()) as Json;
      root = j['root'] ?? '';
      mediaRoot = j['media_root'] ?? '';
      for (final r in (j['records'] as List? ?? [])) {
        final record = LocalRecord.fromJson(r);
        records[record.asset.id] = record;
      }
    }
  }

  @override
  Future<void> save() {
    final snapshot = jsonEncode({
      'root': root,
      'media_root': mediaRoot,
      'records': records.values.map((r) => r.toJson()).toList(),
    });
    _writes = _writes.catchError((Object _) {}).then((_) async {
      final tmp = File('${_index.path}.tmp');
      await tmp.writeAsString(snapshot, flush: true);
      await tmp.rename(_index.path);
    });
    return _writes;
  }

  @override
  Future<List<LocalEntry>> gallery() async {
    if (!Platform.isAndroid) return pickFiles();
    final result = await channel.invokeListMethod<dynamic>('listMedia');
    return (result ?? [])
        .map((v) => LocalEntry.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList();
  }

  @override
  Future<List<LocalEntry>> pickFiles() async {
    final result = await FilePicker.pickFiles(allowMultiple: true);
    if (result == null) return [];
    return Future.wait(
      result.files
          .where((f) => f.path != null)
          .map((f) => _entry(File(f.path!))),
    );
  }

  @override
  Future<ApplePhotosImportResult?> importApplePhotos(
    void Function(int done, int total) progress,
  ) async {
    if (!Platform.isMacOS) {
      throw UnsupportedError('Apple Photos import requires macOS.');
    }
    final repository = root;
    final hasMediaFolder = mediaRoot.isNotEmpty;
    final media = hasMediaFolder ? mediaRoot : p.join(repository, 'Media');
    if (repository.isEmpty ||
        !await Directory(repository).exists() ||
        (hasMediaFolder && !await Directory(media).exists())) {
      throw StateError('Connect your Haven storage folder and retry.');
    }
    final path = await _photosImport.invokeMethod<String>('chooseLibrary');
    if (path == null) return null;
    final library = await ApplePhotosLibrary.read(path);
    for (final directory in {repository, if (hasMediaFolder) media}) {
      final resolved = await Directory(directory).resolveSymbolicLinks();
      if (p.equals(resolved, library.directory.path) ||
          p.isWithin(library.directory.path, resolved)) {
        throw StateError(
          'Choose Haven storage outside the Apple Photos library.',
        );
      }
    }
    return copyApplePhotos(
      library,
      media: (relative) => !hasMediaFolder
          ? _safeFile(repository, 'Media/$relative')
          : _safeFile(media, relative),
      files: (relative) => _safeFile(repository, 'Files/$relative'),
      mime: _mime,
      progress: progress,
    );
  }

  @override
  Future<ApplePhotosArchiveResult?> archiveApplePhotosLibrary() async {
    final repository = root;
    if (repository.isEmpty || !await Directory(repository).exists()) {
      throw StateError('Connect your Haven storage folder and retry.');
    }
    final path = await _photosImport.invokeMethod<String>('chooseLibrary');
    if (path == null) return null;
    final source = await Directory(path).resolveSymbolicLinks();
    final target = await Directory(repository).resolveSymbolicLinks();
    if (p.equals(source, target) || p.isWithin(source, target)) {
      throw StateError(
        'Choose Haven storage outside the Apple Photos library.',
      );
    }
    final staging = await _safeFile(repository, '.haven/archive-staging/item');
    return archiveApplePhotos(
      path,
      staging.parent,
      (relative) =>
          _safeFile(repository, 'Files/Apple Photos Archives/$relative'),
    );
  }

  @override
  Future<String?> restoreApplePhotosLibrary() async {
    final archive = await _photosImport.invokeMethod<String>('chooseArchive');
    if (archive == null) return null;
    final folder = await _photosImport.invokeMethod<String>(
      'chooseRestoreFolder',
    );
    if (folder == null) return null;
    return restoreApplePhotosArchive(File(archive), Directory(folder));
  }

  @override
  Future<String?> chooseDirectory() => Platform.isMacOS
      ? _photosImport.invokeMethod<String>('chooseFolder')
      : FilePicker.getDirectoryPath();
  String _mime(String path) => switch (p.extension(path).toLowerCase()) {
    '.jpg' || '.jpeg' => 'image/jpeg',
    '.png' => 'image/png',
    '.webp' => 'image/webp',
    '.gif' => 'image/gif',
    '.heic' => 'image/heic',
    '.heif' => 'image/heif',
    '.tif' || '.tiff' => 'image/tiff',
    '.bmp' => 'image/bmp',
    '.dng' => 'image/x-adobe-dng',
    '.cr2' || '.cr3' => 'image/x-canon-raw',
    '.nef' || '.nrw' => 'image/x-nikon-raw',
    '.arw' => 'image/x-sony-arw',
    '.raf' => 'image/x-fuji-raf',
    '.orf' => 'image/x-olympus-orf',
    '.rw2' => 'image/x-panasonic-rw2',
    '.avif' => 'image/avif',
    '.mp4' => 'video/mp4',
    '.mov' => 'video/quicktime',
    '.m4v' => 'video/mp4',
    '.avi' => 'video/x-msvideo',
    '.mkv' => 'video/x-matroska',
    '.mp3' => 'audio/mpeg',
    '.wav' => 'audio/wav',
    '.m4a' => 'audio/mp4',
    '.json' => 'application/json',
    _ => 'application/octet-stream',
  };
  Future<LocalEntry> _entry(File file) async {
    final st = await file.stat();
    return LocalEntry(
      ref: file.path,
      name: p.basename(file.path),
      mime: _mime(file.path),
      size: st.size,
      modified: st.modified.microsecondsSinceEpoch,
      captured: st.modified.microsecondsSinceEpoch,
    );
  }

  @override
  Future<List<LocalEntry>> scanRoot() async {
    if (root.isEmpty) return [];
    final entries = <LocalEntry>[];
    Future<void> visit(Directory d) async {
      if (!await d.exists()) return;
      await for (final entity in d.list(followLinks: false)) {
        if (p.basename(entity.path).startsWith('.haven')) continue;
        if (entity is Directory) {
          if (p.extension(entity.path).toLowerCase() == '.photoslibrary') {
            continue;
          }
          await visit(entity);
        } else if (entity is File) {
          entries.add(await _entry(entity));
        }
      }
    }

    for (final dir in [
      Directory(p.join(root, 'Media')),
      Directory(p.join(root, 'Files')),
      Directory(p.join(root, 'Structured')),
    ]) {
      await visit(dir);
    }
    if (mediaRoot.isNotEmpty && !p.equals(mediaRoot, p.join(root, 'Media'))) {
      await visit(Directory(mediaRoot));
    }
    return entries;
  }

  @override
  Future<Uint8List> read(LocalEntry entry, int offset, int length) async {
    if (entry.ref.startsWith('content:')) {
      return (await channel.invokeMethod<Uint8List>('readChunk', {
        'uri': entry.ref,
        'offset': offset,
        'length': length,
      }))!;
    }
    final file = await File(entry.ref).open();
    try {
      await file.setPosition(offset);
      return await file.read(length);
    } finally {
      await file.close();
    }
  }

  @override
  Future<String> digest(LocalEntry entry) async {
    final result = _DigestSink();
    final sink = sha256.startChunkedConversion(result);
    var offset = 0;
    while (offset < entry.size) {
      final b = await read(entry, offset, min(1 << 20, entry.size - offset));
      if (b.isEmpty) throw StateError('File changed while reading');
      sink.add(b);
      offset += b.length;
    }
    sink.close();
    return result.value.toString();
  }

  @override
  Future<Uint8List?> thumbnail(LocalEntry entry) async {
    try {
      if (entry.ref.startsWith('content:')) {
        return await channel.invokeMethod<Uint8List>('thumbnail', {
          'uri': entry.ref,
        });
      }
      if (!entry.mime.startsWith('image/') || entry.size > 32 << 20) {
        return null;
      }
      final codec = await ui.instantiateImageCodec(
        await File(entry.ref).readAsBytes(),
        targetWidth: 160,
        targetHeight: 160,
      );
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      if (data == null || data.lengthInBytes > 128 << 10) return null;
      return data.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  String _base(MediaAsset asset) =>
      asset.kind == 'media' && mediaRoot.isNotEmpty ? mediaRoot : root;
  String _relative(MediaAsset asset) =>
      asset.kind == 'media' && mediaRoot.isNotEmpty
      ? asset.path.substring('Media/'.length)
      : asset.path;
  Future<File> _safeFile(String base, String relative) async {
    if (base.isEmpty ||
        p.isAbsolute(relative) ||
        relative.split('/').any((s) => s == '..' || s == '.' || s.isEmpty) ||
        relative.contains('\\')) {
      throw StateError('Unsafe repository path');
    }
    final baseDir = Directory(base);
    await baseDir.create(recursive: true);
    final resolved = await baseDir.resolveSymbolicLinks();
    final parts = relative.split('/');
    var current = resolved;
    for (final part in parts.take(parts.length - 1)) {
      current = p.join(current, part);
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw StateError('Symlink in repository path');
      }
      await Directory(current).create();
    }
    final file = File(p.join(current, parts.last));
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('Symlink at destination');
    }
    return file;
  }

  Future<File> _partial(MediaAsset asset) => _safeFile(
    _base(asset),
    '.haven/partials/${asset.id}-${asset.revision}.part',
  );
  @override
  Future<int> partialLength(MediaAsset asset) async {
    final f = await _partial(asset);
    return await f.exists() ? f.length() : 0;
  }

  @override
  Future<void> append(MediaAsset asset, int offset, Uint8List bytes) async {
    final f = await _partial(asset);
    final n = await f.exists() ? await f.length() : 0;
    if (n != offset || offset + bytes.length > asset.size) {
      throw StateError('Unexpected transfer offset');
    }
    final handle = await f.open(mode: FileMode.append);
    try {
      await handle.writeFrom(bytes);
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  @override
  Future<LocalEntry> commit(MediaAsset asset) async {
    final partial = await _partial(asset);
    final digestValue = (await sha256.bind(partial.openRead()).first)
        .toString();
    if (await partial.length() != asset.size || digestValue != asset.hash) {
      await partial.delete();
      throw StateError('Hash verification failed; partial discarded');
    }
    final destination = await _safeFile(_base(asset), _relative(asset));
    if (await destination.exists()) {
      final actual = (await sha256.bind(destination.openRead()).first)
          .toString();
      if (actual != asset.hash) {
        final old = records[asset.id];
        if (old == null || actual != old.asset.hash) {
          throw StateError(
            'Local edit pending. Scan local changes before receiving.',
          );
        }
        final history = await _safeFile(
          _base(asset),
          '.haven/history/${asset.id}-$actual-${DateTime.now().microsecondsSinceEpoch}',
        );
        await destination.rename(history.path);
      } else {
        await partial.delete();
        return _entry(destination);
      }
    }
    await partial.rename(destination.path);
    return _entry(destination);
  }

  @override
  Future<LocalEntry> relocate(LocalEntry entry, MediaAsset asset) async {
    if (entry.ref.startsWith('content:') || root.isEmpty) return entry;
    final inside =
        p.isWithin(root, entry.ref) ||
        (mediaRoot.isNotEmpty && p.isWithin(mediaRoot, entry.ref));
    if (!inside) return entry;
    final destination = await _safeFile(_base(asset), _relative(asset));
    if (p.equals(entry.ref, destination.path)) return entry;
    if (await destination.exists()) {
      throw StateError('Conflict destination already exists');
    }
    await File(entry.ref).rename(destination.path);
    return _entry(destination);
  }
}
