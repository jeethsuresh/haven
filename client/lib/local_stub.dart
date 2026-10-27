import 'dart:typed_data';
import 'model.dart';

LocalRepository createRepository() => _BrowserRepository();

class _BrowserRepository extends LocalRepository {
  @override
  Future<void> load(String account) async {}
  @override
  Future<void> save() async {}
  Never unsupported() =>
      throw UnsupportedError('Use the Android or desktop app for originals.');
  @override
  Future<List<LocalEntry>> gallery() async => unsupported();
  @override
  Future<List<LocalEntry>> pickFiles() async => unsupported();
  @override
  Future<String?> chooseDirectory() async => unsupported();
  @override
  Future<List<LocalEntry>> scanRoot() async => [];
  @override
  Future<Uint8List> read(LocalEntry entry, int offset, int length) async =>
      unsupported();
  @override
  Future<String> digest(LocalEntry entry) async => unsupported();
  @override
  Future<Uint8List?> thumbnail(LocalEntry entry) async => null;
  @override
  Future<int> partialLength(MediaAsset asset) async => unsupported();
  @override
  Future<void> append(MediaAsset asset, int offset, Uint8List bytes) async =>
      unsupported();
  @override
  Future<LocalEntry> commit(MediaAsset asset) async => unsupported();
  @override
  Future<LocalEntry> relocate(LocalEntry entry, MediaAsset asset) async =>
      unsupported();
}
