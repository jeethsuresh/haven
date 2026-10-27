import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/local_io.dart';
import 'package:haven/model.dart';

MediaAsset asset(
  List<int> bytes, {
  String path = 'Media/2026/10/photo.jpg',
  String revision = '22222222222222222222222222222222',
}) => MediaAsset({
  'id': '11111111111111111111111111111111',
  'kind': 'media',
  'path': path,
  'mime': 'image/jpeg',
  'captured': 0,
  'revisions': [
    {
      'id': revision,
      'sha256': sha256.convert(bytes).toString(),
      'size': bytes.length,
      'device_id': 'source',
      'created': 0,
    },
  ],
});
void main() {
  late Directory temp;
  late DiskRepository repo;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('haven-test-');
    repo = DiskRepository()..root = temp.path;
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });
  test(
    'partial transfer resumes on disk and commits only after hash verification',
    () async {
      final bytes = List<int>.generate(70000, (i) => i % 251);
      final a = asset(bytes);
      await repo.append(a, 0, Uint8List.fromList(bytes.take(16384).toList()));
      final restarted = DiskRepository()..root = temp.path;
      expect(await restarted.partialLength(a), 16384);
      await restarted.append(
        a,
        16384,
        Uint8List.fromList(bytes.skip(16384).toList()),
      );
      final entry = await restarted.commit(a);
      expect(await File(entry.ref).readAsBytes(), bytes);
      expect(await restarted.partialLength(a), 0);
    },
  );
  test('corrupt partial is rejected and removed', () async {
    final a = asset([1, 2, 3]);
    await repo.append(a, 0, Uint8List.fromList([1, 2, 9]));
    await expectLater(repo.commit(a), throwsStateError);
    expect(await repo.partialLength(a), 0);
    expect(await File('${temp.path}/${a.path}').exists(), isFalse);
  });
  test('out-of-order or oversized chunks cannot change a partial', () async {
    final a = asset([1, 2, 3]);
    await repo.append(a, 0, Uint8List.fromList([1]));
    await expectLater(
      repo.append(a, 0, Uint8List.fromList([9])),
      throwsStateError,
    );
    await expectLater(
      repo.append(a, 1, Uint8List.fromList([2, 3, 4])),
      throwsStateError,
    );
    expect(await repo.partialLength(a), 1);
  });
  test(
    'replacement retains the previous original; unsent local edits block overwrite',
    () async {
      final first = asset([1, 2, 3]);
      await repo.append(first, 0, Uint8List.fromList([1, 2, 3]));
      final entry = await repo.commit(first);
      repo.records[first.id] = LocalRecord(first, entry);
      final second = asset([
        4,
        5,
        6,
      ], revision: '33333333333333333333333333333333');
      await repo.append(second, 0, Uint8List.fromList([4, 5, 6]));
      await repo.commit(second);
      final history = await Directory(
        '${temp.path}/.haven/history',
      ).list().toList();
      expect(history, hasLength(1));
      expect(await File(history.single.path).readAsBytes(), [1, 2, 3]);
      await File(entry.ref).writeAsBytes([7, 8, 9]);
      final third = asset([
        9,
        9,
        9,
      ], revision: '44444444444444444444444444444444');
      await repo.append(third, 0, Uint8List.fromList([9, 9, 9]));
      await expectLater(repo.commit(third), throwsStateError);
      expect(await File(entry.ref).readAsBytes(), [7, 8, 9]);
    },
  );
  test(
    'repository refuses traversal and symlink destinations',
    () async {
      final a = asset([1], path: 'Media/../../escape');
      await repo.append(a, 0, Uint8List.fromList([1]));
      await expectLater(repo.commit(a), throwsStateError);
      final outside = await Directory.systemTemp.createTemp('haven-outside-');
      try {
        await Link('${temp.path}/Media').create(outside.path);
        final b = asset([2], revision: '55555555555555555555555555555555');
        await repo.append(b, 0, Uint8List.fromList([2]));
        await expectLater(repo.commit(b), throwsStateError);
        expect(await outside.list().toList(), isEmpty);
      } finally {
        await outside.delete(recursive: true);
      }
    },
    skip: Platform.isWindows
        ? 'Symlink creation requires a privileged Windows runner'
        : false,
  );
  test('media can use a delegated folder', () async {
    repo.mediaRoot = '${temp.path}/external-media';
    final a = asset([1, 2]);
    await repo.append(a, 0, Uint8List.fromList([1, 2]));
    final entry = await repo.commit(a);
    expect(entry.ref, '${repo.mediaRoot}/2026/10/photo.jpg');
  });
}
