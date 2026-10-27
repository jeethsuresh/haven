import 'dart:typed_data';

typedef Json = Map<String, dynamic>;

class MediaAsset {
  final Json data;
  final int copies;
  MediaAsset(this.data, [this.copies = 0]);
  String get id => data['id'] as String;
  String get kind => data['kind'] as String;
  String get path => data['path'] as String;
  String get name => path.split('/').last;
  String get mime => data['mime'] as String;
  Json get head => (data['revisions'] as List).last as Json;
  String get revision => head['id'] as String;
  String get hash => head['sha256'] as String;
  int get size => head['size'] as int;
}

class LocalEntry {
  final String ref, name, mime;
  final int size, modified, captured;
  const LocalEntry({
    required this.ref,
    required this.name,
    required this.mime,
    required this.size,
    required this.modified,
    required this.captured,
  });
  factory LocalEntry.fromJson(Json j) => LocalEntry(
    ref: j['ref'],
    name: j['name'],
    mime: j['mime'],
    size: j['size'],
    modified: j['modified'],
    captured: j['captured'],
  );
  Json toJson() => {
    'ref': ref,
    'name': name,
    'mime': mime,
    'size': size,
    'modified': modified,
    'captured': captured,
  };
}

class LocalRecord {
  final MediaAsset asset;
  final LocalEntry entry;
  LocalRecord(this.asset, this.entry);
  factory LocalRecord.fromJson(Json j) =>
      LocalRecord(MediaAsset(j['asset']), LocalEntry.fromJson(j['entry']));
  Json toJson() => {'asset': asset.data, 'entry': entry.toJson()};
}

abstract class LocalRepository {
  String root = '';
  String mediaRoot = '';
  final Map<String, LocalRecord> records = {};
  Future<void> load(String account);
  Future<void> save();
  Future<List<LocalEntry>> gallery();
  Future<List<LocalEntry>> pickFiles();
  Future<String?> chooseDirectory();
  Future<List<LocalEntry>> scanRoot();
  Future<Uint8List> read(LocalEntry entry, int offset, int length);
  Future<String> digest(LocalEntry entry);
  Future<Uint8List?> thumbnail(LocalEntry entry);
  Future<int> partialLength(MediaAsset asset);
  Future<void> append(MediaAsset asset, int offset, Uint8List bytes);
  Future<LocalEntry> commit(MediaAsset asset);
  Future<LocalEntry> relocate(LocalEntry entry, MediaAsset asset);
}

String readableBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) {
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}
