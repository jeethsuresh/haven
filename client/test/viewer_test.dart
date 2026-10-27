import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:haven/api.dart';
import 'package:haven/controller.dart';
import 'package:haven/local_stub.dart';
import 'package:haven/model.dart';
import 'package:haven/thumbnail_cache.dart';

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+X2ioAAAAASUVORK5CYII=',
);
MediaAsset media([String revision = 'r1']) => MediaAsset({
  'id': 'a1',
  'kind': 'media',
  'path': 'Media/photo.png',
  'mime': 'image/png',
  'captured': 0,
  'revisions': [
    {'id': revision, 'sha256': 'original-hash', 'size': 1000},
  ],
});

class LimitedStorage extends MemoryThumbnailStorage {
  int limit = 250;
  @override
  void write(String key, String value) {
    if (value.length > limit) throw StateError('quota');
    super.write(key, value);
  }
}

void main() {
  test(
    'cache survives reload, isolates accounts and invalidates revisions',
    () {
      final storage = MemoryThumbnailStorage();
      final cache = ThumbnailCache(storage, fail)..load('account-one');
      cache.put(media(), png);
      final reloaded = ThumbnailCache(storage, fail)..load('account-one');
      expect(reloaded.get(media()), png);
      expect(reloaded.get(media('r2')), isNull);
      reloaded.load('account-two');
      expect(reloaded.get(media()), isNull);
      reloaded.load('account-one');
      reloaded.put(media('r2'), png);
      expect(reloaded.get(media()), isNull);
      expect(reloaded.get(media('r2')), png);
      reloaded.clear();
      expect(
        (ThumbnailCache(storage, fail)..load('account-one')).get(media('r2')),
        isNull,
      );
    },
  );
  test(
    'bounded cache evicts oldest and tolerates unavailable local storage',
    () {
      final storage = LimitedStorage();
      final warnings = <String>[];
      final cache = ThumbnailCache(storage, warnings.add, maxCharacters: 500)
        ..load('one');
      cache.put(media(), png);
      final second = MediaAsset({...media().data, 'id': 'a2'});
      cache.put(second, png);
      final third = MediaAsset({...media().data, 'id': 'a3'});
      cache.put(third, png);
      expect(cache.get(media()), isNull);
      expect(cache.get(third), png);
      storage.limit = 0;
      cache.put(third, png);
      expect(cache.get(third), png);
      expect(warnings, hasLength(1));
    },
  );
  test('peer images reject oversized frames, dimensions and checksums', () {
    expect(() => validateThumbnail(Uint8List(129 << 10)), throwsStateError);
    final bomb = Uint8List.fromList(png);
    ByteData.sublistView(bomb).setUint32(16, 1000000);
    expect(() => validateThumbnail(bomb), throwsStateError);
    expect(() => validateThumbnail(png, expectedHash: 'bad'), throwsStateError);
    expect(
      () => validateThumbnail(Uint8List.fromList([1, 2, 3])),
      throwsStateError,
    );
  });
  test(
    'cache hit performs no HTTP; miss requests only metadata and caches peer reply',
    () async {
      final calls = <http.Request>[];
      final api = HavenApi(
        client: MockClient((req) async {
          calls.add(req);
          expect(req.url.path, '/api/thumbnail-requests');
          expect(jsonDecode(req.body), {'asset_id': 'a1', 'revision_id': 'r2'});
          return http.Response('{}', 200);
        }),
      );
      final c = HavenController(api: api, local: createRepository())
        ..ready = true;
      c.thumbnails.load('test');
      c.thumbnails.put(media(), png);
      expect(await c.thumbnail(media()), png);
      expect(calls, isEmpty);
      final first = c.thumbnail(media('r2'));
      final second = c.thumbnail(media('r2'));
      await Future<void>.delayed(Duration.zero);
      expect(calls, hasLength(1));
      c.thumbnails.put(media('r2'), png);
      c.peers.receivedThumbnail(media('r2'), png);
      expect(await first, png);
      expect(await second, png);
      expect(await c.thumbnail(media('r2')), png);
      expect(calls, hasLength(1));
      c.dispose();
    },
  );
  test(
    'source reports pending originals and active errors without thumbnail bytes',
    () async {
      late Json sent;
      final api = HavenApi(
        client: MockClient((req) async {
          expect(req.url.path, '/api/reports');
          sent = jsonDecode(req.body) as Json;
          return http.Response('{}', 200);
        }),
      );
      final c = HavenController(api: api, local: createRepository())
        ..roles = ['viewer', 'source']
        ..deviceID = 'phone'
        ..assets = [media()]
        ..transfers = [
          {
            'id': 'copy',
            'from': 'phone',
            'to': 'desktop',
            'asset_id': 'a1',
            'revision_id': 'r1',
            'status': 'waiting_for_peer',
          },
          {
            'id': 'thumb',
            'purpose': 'thumbnail',
            'from': 'phone',
            'to': 'browser',
            'asset_id': 'a1',
            'revision_id': 'r1',
            'status': 'connecting',
          },
        ];
      c.recordIssue('transfer:copy', 'No direct route', 'a1');
      await c.sendReport();
      expect(sent['pending_count'], 1);
      expect((sent['pending'] as List).single['direction'], 'send');
      expect((sent['errors'] as List).single['message'], 'No direct route');
      c.transfers.first['status'] = 'complete';
      c.assets = [MediaAsset(media().data, 1)];
      await c.sendReport();
      expect(sent['pending_count'], 0);
      expect(sent['errors'], isEmpty);
      c.transfers.clear();
      c.assets = [media()];
      c.local.records['a1'] = LocalRecord(
        media(),
        const LocalEntry(
          ref: 'local',
          name: 'photo.png',
          mime: 'image/png',
          size: 1000,
          modified: 0,
          captured: 0,
        ),
      );
      await c.sendReport();
      expect(
        sent['pending_count'],
        1,
        reason: 'A source without any sink still has an unsynced original',
      );
      c.dispose();
    },
  );
}
