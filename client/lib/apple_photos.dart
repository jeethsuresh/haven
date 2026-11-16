import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'model.dart';

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final _component = RegExp(r'^[^/\\\x00]+$');
final _extension = RegExp(r'^\.[a-zA-Z0-9]{1,12}$');
final _rawCompanion = RegExp(
  r'^(.+)_4\.(arw|cr2|cr3|dng|nef|nrw|orf|raf|rw2|pef|srw)$',
  caseSensitive: false,
);

typedef _Destination = Future<File> Function(String relative);

/// Reads the catalog from a private SQLite copy. Apple Photos never opens the
/// imported library and Haven never writes into the selected package.
class ApplePhotosLibrary {
  ApplePhotosLibrary._(this.directory, this.id, this.assets, this.albums);

  final Directory directory;
  final String id;
  final List<Json> assets, albums;
  final _rawByDirectory = <String, Map<String, File>>{};

  static Future<ApplePhotosLibrary> read(
    String path, {
    bool verifyIntegrity = false,
  }) async {
    if (p.extension(path).toLowerCase() != '.photoslibrary') {
      throw const FormatException('Choose a .photoslibrary package.');
    }
    final root = Directory(await Directory(path).resolveSymbolicLinks());
    final database = await _fileIn(root, ['database', 'Photos.sqlite']);
    if (database == null) {
      throw const FormatException(
        'This Apple Photos library has no supported Photos database.',
      );
    }
    final scratch = await Directory.systemTemp.createTemp('haven-photos-');
    try {
      final copy = File(p.join(scratch.path, 'Photos.sqlite'));
      final wal = await _fileIn(root, ['database', 'Photos.sqlite-wal']);
      final dbBefore = await database.stat();
      final walBefore = await wal?.stat();
      await database.copy(copy.path);
      await wal?.copy('${copy.path}-wal');
      final walAfter = await _fileIn(root, ['database', 'Photos.sqlite-wal']);
      if (!_sameSnapshot(dbBefore, await database.stat()) ||
          !_sameSnapshot(walBefore, await walAfter?.stat())) {
        throw StateError(
          'The Apple Photos library changed while reading it. Quit Photos and retry.',
        );
      }
      if (verifyIntegrity) {
        final check = await _query(copy, 'PRAGMA quick_check;');
        if (check.length != 1 || check.single.values.single != 'ok') {
          throw const FormatException(
            'The Apple Photos database failed integrity verification.',
          );
        }
      }

      final schema = await _query(copy, '''
        SELECT m.name AS table_name, c.name AS column_name
        FROM sqlite_schema AS m JOIN pragma_table_info(m.name) AS c
        WHERE m.type = 'table'
      ''');
      final tables = <String, Set<String>>{};
      for (final row in schema) {
        (tables[row['table_name'] as String] ??= {}).add(
          row['column_name'] as String,
        );
      }
      const required = {'Z_PK', 'ZUUID', 'ZFILENAME', 'ZDIRECTORY', 'ZKIND'};
      final table = ['ZASSET', 'ZGENERICASSET']
          .where((name) => tables[name]?.containsAll(required) ?? false)
          .firstOrNull;
      if (table == null ||
          !(tables['Z_METADATA']?.contains('Z_UUID') ?? false)) {
        throw const FormatException(
          'Unsupported Apple Photos database format.',
        );
      }
      final metadata = await _query(
        copy,
        'SELECT Z_UUID AS id FROM Z_METADATA',
      );
      final id = metadata.firstOrNull?['id'];
      if (id is! String || !_uuid.hasMatch(id)) {
        throw const FormatException(
          'The Photos database is missing its library ID.',
        );
      }
      final assetColumns = tables[table]!;
      String assetColumn(String column) =>
          assetColumns.contains(column) ? 'a.$column' : 'NULL';
      final attrs = tables['ZADDITIONALASSETATTRIBUTES'] ?? {};
      final hasAttrs =
          attrs.contains('Z_PK') &&
          assetColumns.contains('ZADDITIONALATTRIBUTES');
      String attr(String column) =>
          hasAttrs && attrs.contains(column) ? 'x.$column' : 'NULL';
      final assets = await _query(copy, '''
        SELECT a.Z_PK AS pk, a.ZUUID AS id, a.ZDIRECTORY AS directory,
          a.ZFILENAME AS filename, a.ZKIND AS kind,
          ${attr('ZORIGINALFILENAME')} AS original_name,
          ${attr('ZTITLE')} AS title,
          ${assetColumn('ZDATECREATED')} AS capture,
          ${assetColumn('ZHIDDEN')} AS hidden,
          ${assetColumn('ZKINDSUBTYPE')} AS subtype,
          COALESCE(${assetColumn('ZADJUSTMENTSSTATE')}, ${assetColumn('ZHASADJUSTMENTS')},
            ${assetColumn('ZADJUSTMENTTIMESTAMP')} IS NOT NULL) AS adjusted
        FROM $table AS a
        ${hasAttrs ? 'LEFT JOIN ZADDITIONALASSETATTRIBUTES AS x ON x.Z_PK = a.ZADDITIONALATTRIBUTES' : ''}
        WHERE a.ZKIND IN (0, 1) AND COALESCE(${assetColumn('ZTRASHEDSTATE')}, 0) = 0
        ORDER BY a.Z_PK
      ''');
      return ApplePhotosLibrary._(
        root,
        id.toLowerCase(),
        assets,
        await _readAlbums(copy, tables),
      );
    } finally {
      await scratch.delete(recursive: true);
    }
  }

  static bool _sameSnapshot(FileStat? a, FileStat? b) =>
      a?.type == b?.type &&
      a?.size == b?.size &&
      a?.modified == b?.modified &&
      a?.changed == b?.changed;

  static Future<List<Json>> _query(File database, String sql) async {
    final result = await Process.run('/usr/bin/sqlite3', [
      '-init',
      '/dev/null',
      '-batch',
      '-bail',
      '-safe',
      '-readonly',
      '-json',
      database.path,
      'PRAGMA trusted_schema=OFF; $sql',
    ]);
    if (result.exitCode != 0) {
      throw const FormatException(
        'Haven could not read the Apple Photos database.',
      );
    }
    final output = (result.stdout as String).trim();
    if (output.isEmpty) return [];
    return (jsonDecode(output) as List).cast<Json>();
  }

  static Future<List<Json>> _readAlbums(
    File database,
    Map<String, Set<String>> tables,
  ) async {
    final columns = tables['ZGENERICALBUM'];
    if (columns == null ||
        !columns.containsAll({'Z_PK', 'ZUUID', 'ZTITLE', 'ZKIND'})) {
      throw const FormatException('Unsupported Apple Photos album format.');
    }
    final parents = columns.contains('ZPARENTFOLDER')
        ? 'ZPARENTFOLDER'
        : 'NULL';
    final trashed = columns.contains('ZTRASHEDSTATE')
        ? 'ZTRASHEDSTATE'
        : 'NULL';
    final albums = await _query(database, '''
      SELECT Z_PK AS pk, ZUUID AS id, ZTITLE AS title, ZKIND AS kind,
        $parents AS parent
      FROM ZGENERICALBUM WHERE COALESCE($trashed, 0) = 0 ORDER BY Z_PK
    ''');
    final members = <int, List<int>>{};
    final albumTable = RegExp(r'^Z_\d+ASSETS$');
    for (final entry in tables.entries.where(
      (e) => albumTable.hasMatch(e.key),
    )) {
      final left = entry.value
          .where((c) => RegExp(r'^Z_\d+ALBUMS$').hasMatch(c))
          .firstOrNull;
      final right = entry.value
          .where((c) => RegExp(r'^Z_\d+ASSETS$').hasMatch(c))
          .firstOrNull;
      if (left == null || right == null) continue;
      final order = 'Z_FOK_${right.substring(2)}';
      final sort = entry.value.contains(order)
          ? '$left, $order, $right'
          : '$left, $right';
      for (final link in await _query(database, '''
        SELECT $left AS album, $right AS asset FROM ${entry.key} ORDER BY $sort
      ''')) {
        if (link['album'] case final int album) {
          if (link['asset'] case final int asset) {
            (members[album] ??= []).add(asset);
          }
        }
      }
    }
    final byPk = {for (final a in albums) a['pk']: a};
    final result = <Json>[];
    for (final album in albums) {
      final title = album['title'];
      // 2 is an ordinary user album; 4000 is a user-created folder.
      if (title is! String || title.isEmpty || album['kind'] != 2) {
        continue;
      }
      final folders = <String>[];
      final seen = <Object?>{album['pk']};
      var parent = album['parent'];
      while (parent != null && seen.add(parent)) {
        final folder = byPk[parent];
        if (folder == null) break;
        if (folder['title'] case final String name
            when folder['kind'] == 4000) {
          folders.add(name);
        }
        parent = folder['parent'];
      }
      result.add({
        'id': album['id'],
        'name': title,
        'folders': folders.reversed.toList(),
        'members': members[album['pk']] ?? <int>[],
      });
    }
    return result;
  }

  static Future<File?> _fileIn(Directory root, List<String> parts) async {
    if (parts.any((s) => s == '.' || s == '..' || !_component.hasMatch(s))) {
      return null;
    }
    var path = root.path;
    for (final (i, part) in parts.indexed) {
      path = p.join(path, part);
      final expected = i == parts.length - 1
          ? FileSystemEntityType.file
          : FileSystemEntityType.directory;
      if (await FileSystemEntity.type(path, followLinks: false) != expected) {
        return null;
      }
    }
    return File(path);
  }

  Future<File?> original(Json asset) async {
    final dir = asset['directory'];
    final file = asset['filename'];
    if (dir is! String || file is! String) return null;
    return _fileIn(directory, ['originals', ...dir.split('/'), file]);
  }

  Future<File?> liveVideo(File original) => _fileIn(directory, [
    ...p.split(p.relative(original.parent.path, from: directory.path)),
    '${p.basenameWithoutExtension(original.path)}_3.mov',
  ]);

  Future<File?> rawCompanion(File original) async {
    final parent = original.parent;
    var files = _rawByDirectory[parent.path];
    if (files == null) {
      files = {};
      await for (final entity in parent.list(followLinks: false)) {
        if (entity is! File) continue;
        final match = _rawCompanion.firstMatch(p.basename(entity.path));
        if (match != null) files[match[1]!] = entity;
      }
      _rawByDirectory[parent.path] = files;
    }
    return files[p.basenameWithoutExtension(original.path)];
  }

  Future<File?> rendered(Json asset, {bool liveVideo = false}) async {
    final id = asset['id'] as String;
    final file = asset['filename'] as String?;
    final shard = id[0];
    final shortName = p.basenameWithoutExtension(file ?? id);
    final ext = p.extension(file ?? '');
    final video = asset['kind'] == 1 || liveVideo;
    final extensions = video
        ? {'.mov', '.mp4'}
        : {
            '.jpeg',
            '.jpg',
            '.heic',
            '.png',
            '.tiff',
            ext.toLowerCase(),
            ext.toUpperCase(),
          };
    final marker = liveVideo
        ? '_2_100_a'
        : video
        ? '_2_0_a'
        : '_1_201_a';
    for (final stem in {'$id$marker', '$shortName$marker'}) {
      for (final suffix in extensions.where(_extension.hasMatch)) {
        final location = await _fileIn(directory, [
          'resources',
          'renders',
          shard,
          '$stem$suffix',
        ]);
        if (location != null) return location;
      }
    }
    return null;
  }
}

/// Copies one resource at a time, verifying the bytes on the destination
/// before publishing a file. Content-based filenames make retries safe.
Future<ApplePhotosImportResult> copyApplePhotos(
  ApplePhotosLibrary library, {
  required Future<File> Function(String relative) media,
  required Future<File> Function(String relative) files,
  required String Function(String) mime,
  required void Function(int done, int total) progress,
}) async {
  final libraryPath = 'Apple Photos/${library.id}';
  final entries = <LocalEntry>[];
  final assets = <Json>[];
  final ids = <int, String>{};
  var missingOriginals = 0, missingEdits = 0, missingLiveVideos = 0;
  for (final (index, asset) in library.assets.indexed) {
    progress(index, library.assets.length);
    final id = asset['id'];
    if (id is! String || !_uuid.hasMatch(id)) {
      throw const FormatException(
        'The Photos database has an invalid photo ID.',
      );
    }
    ids[asset['pk'] as int] = id;
    final origin = await library.original(asset);
    final adjusted = (asset['adjusted'] as num? ?? 0) > 0;
    final edit = adjusted ? await library.rendered(asset) : null;
    final live = asset['kind'] == 0 && asset['subtype'] == 2;
    final motion = live && origin != null
        ? await library.liveVideo(origin)
        : null;
    final editedMotion = live && adjusted
        ? await library.rendered(asset, liveVideo: true)
        : null;
    final raw = origin != null && asset['kind'] == 0
        ? await library.rawCompanion(origin)
        : null;
    if (origin == null) missingOriginals++;
    if (adjusted && edit == null) missingEdits++;
    if (live && motion == null) missingLiveVideos++;
    final name =
        (asset['original_name'] ?? asset['filename'] ?? 'Photo') as String;
    final stem = _fileStem(name);
    final capture = asset['capture'];
    final captured = capture is num && capture.isFinite
        ? ((capture + 978307200) * Duration.microsecondsPerSecond).round()
        : null;
    final parts = <String, String>{};
    for (final (role, file) in [
      ('original', origin),
      ('edited', edit),
      ('live-video', motion),
      ('edited-live-video', editedMotion),
      ('raw', raw),
    ]) {
      if (file == null) continue;
      final ext = p.extension(file.path);
      final suffix = _extension.hasMatch(ext) ? ext.toLowerCase() : '';
      final prefix = '$libraryPath/${id[0].toLowerCase()}/${id.toLowerCase()}';
      final type = mime(file.path);
      final isVideo = asset['kind'] == 1 || role.endsWith('live-video');
      final stored = await _copyResource(
        file,
        media,
        '$prefix/$stem-$role',
        suffix,
        captured,
        type == 'application/octet-stream'
            ? (isVideo ? 'video/octet-stream' : 'image/octet-stream')
            : type,
        'Media',
      );
      parts[role] = stored.$1;
      entries.add(stored.$2);
    }
    assets.add({
      'id': id,
      'name': name,
      if (asset['title'] != null) 'title': asset['title'],
      if (captured != null) 'captured_unix_microseconds': captured,
      'hidden': asset['hidden'] == 1,
      'files': parts,
      if (origin == null) 'missing_original': true,
      if (adjusted && edit == null) 'missing_render': true,
      if (live && motion == null) 'missing_live_video': true,
    });
  }
  final albums = [
    for (final album in library.albums)
      {
        ...album,
        'members': [
          for (final pk in album['members'] as List<int>)
            if (ids.containsKey(pk)) ids[pk],
        ],
      },
  ];
  final count = entries.length;
  final manifest = const JsonEncoder.withIndent('  ').convert({
    'version': 1,
    'library_id': library.id,
    'name': p.basenameWithoutExtension(library.directory.path),
    'assets': assets,
    'albums': albums,
    'missing_originals': missingOriginals,
    'missing_edits': missingEdits,
    'missing_live_videos': missingLiveVideos,
  });
  final scratch = await Directory.systemTemp.createTemp(
    'haven-photos-manifest-',
  );
  try {
    final source = await File(
      p.join(scratch.path, 'library.json'),
    ).writeAsString(manifest);
    final stored = await _copyResource(
      source,
      files,
      '$libraryPath/library',
      '.json',
      null,
      'application/json',
      'Files',
    );
    entries.add(stored.$2);
  } finally {
    await scratch.delete(recursive: true);
  }
  return ApplePhotosImportResult(
    files: count,
    albums: albums.length,
    missingOriginals: missingOriginals,
    missingEdits: missingEdits,
    missingLiveVideos: missingLiveVideos,
    entries: entries,
  );
}

String _fileStem(String name) {
  final clean = p
      .basenameWithoutExtension(name)
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f.]'), '_')
      .trim();
  if (clean.isEmpty) return 'Photo';
  return String.fromCharCodes(clean.runes.take(45));
}

Future<(String, LocalEntry)> _copyResource(
  File source,
  _Destination destination,
  String prefix,
  String extension,
  int? captured,
  String mime,
  String root,
) async {
  final before = await source.stat();
  if (before.type != FileSystemEntityType.file || before.size == 0) {
    throw StateError('A Photos resource is empty or could not be read.');
  }
  final hash = await sha256.bind(source.openRead()).first;
  final relative = '$prefix-${hash.toString().substring(0, 16)}$extension';
  final target = await destination(relative);
  if (!await target.exists()) {
    final staging = await target.parent.createTemp('.haven-import-');
    try {
      final partial = await source.copy(p.join(staging.path, 'file'));
      final storedHash = await sha256.bind(partial.openRead()).first;
      if (storedHash != hash ||
          !ApplePhotosLibrary._sameSnapshot(before, await source.stat())) {
        throw StateError('A copied Photos resource did not pass verification.');
      }
      await partial.setLastModified(
        captured == null
            ? before.modified
            : DateTime.fromMicrosecondsSinceEpoch(captured),
      );
      await partial.rename(target.path);
    } finally {
      await staging.delete(recursive: true);
    }
  } else if (await sha256.bind(target.openRead()).first != hash) {
    throw StateError(
      'A file in the repository differs from the Photos import.',
    );
  }
  final stat = await target.stat();
  return (
    '$root/$relative',
    LocalEntry(
      ref: target.path,
      name: p.basename(target.path),
      mime: mime,
      size: stat.size,
      modified: stat.modified.microsecondsSinceEpoch,
      captured: captured ?? stat.modified.microsecondsSinceEpoch,
    ),
  );
}
