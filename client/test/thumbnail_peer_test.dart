import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:haven/api.dart';
import 'package:haven/local_stub.dart';
import 'package:haven/model.dart';
import 'package:haven/peer.dart';
import 'package:haven/thumbnail_cache.dart';
import 'viewer_test.dart' show png, media;

class TestChannel extends RTCDataChannel {
  TestChannel? remote;
  final List<RTCDataChannelMessage> frames = [];
  @override
  String get label => 'haven-thumbnail-v1';
  @override
  Future<void> send(RTCDataChannelMessage message) async {
    frames.add(message);
    scheduleMicrotask(() => remote!.onMessage?.call(message));
  }

  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class TestConnection extends RTCPeerConnection {
  TestConnection? remote;
  TestChannel? channel;
  @override
  Future<RTCDataChannel> createDataChannel(
    String label,
    RTCDataChannelInit init,
  ) async {
    channel = TestChannel();
    final other = TestChannel();
    channel!.remote = other;
    other.remote = channel;
    remote!.channel = other;
    return channel!;
  }

  @override
  Future<RTCSessionDescription> createOffer([
    Map<String, dynamic>? constraints,
  ]) async => RTCSessionDescription('offer', 'offer');
  @override
  Future<RTCSessionDescription> createAnswer([
    Map<String, dynamic>? constraints,
  ]) async => RTCSessionDescription('answer', 'answer');
  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}
  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    if (description.type == 'offer') onDataChannel?.call(channel!);
    if (description.type == 'answer') {
      channel!.onDataChannelState?.call(RTCDataChannelState.RTCDataChannelOpen);
      remote!.channel!.onDataChannelState?.call(
        RTCDataChannelState.RTCDataChannelOpen,
      );
    }
  }

  @override
  Future<void> close() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'source sends a bounded thumbnail to a browser cache over the data channel',
    () async {
      final from = TestConnection(), to = TestConnection();
      from.remote = to;
      to.remote = from;
      final inbox = <String, List<Json>>{'source': [], 'viewer': []};
      final requests = <http.Request>[];
      final received = Completer<Uint8List>(), receipt = Completer<void>();
      int sequence = 0;
      final job = <String, dynamic>{
        'id': 'thumb',
        'purpose': 'thumbnail',
        'asset_id': 'a1',
        'revision_id': 'r1',
        'from': 'source',
        'to': 'viewer',
        'status': 'waiting_for_peer',
      };
      HavenApi api(String device) => HavenApi(
        client: MockClient((req) async {
          requests.add(req);
          if (req.url.path == '/api/signals' && req.method == 'GET') {
            final items = inbox[device]!.toList();
            inbox[device]!.clear();
            return http.Response(
              jsonEncode({'cursor': sequence, 'signals': items}),
              200,
            );
          }
          final body = jsonDecode(req.body) as Json;
          if (req.url.path == '/api/signals') {
            inbox[device == 'source' ? 'viewer' : 'source']!.add({
              ...body,
              'seq': ++sequence,
            });
          } else if (body['status'] == 'complete') {
            expect(device, 'viewer');
            expect(body['sha256'], sha256.convert(png).toString());
            if (!receipt.isCompleted) receipt.complete();
          }
          return http.Response('{}', 200);
        }),
      );
      final sourceCache = ThumbnailCache(MemoryThumbnailStorage(), fail)
        ..load('source');
      sourceCache.put(media(), png);
      final browserStorage = MemoryThumbnailStorage();
      final viewerCache = ThumbnailCache(browserStorage, fail)..load('viewer');
      final repo = createRepository();
      repo.records['a1'] = LocalRecord(
        media(),
        const LocalEntry(
          ref: 'on-device',
          name: 'photo.png',
          mime: 'image/png',
          size: 1000,
          modified: 0,
          captured: 0,
        ),
      );
      final source =
          DirectPeers(
              api('source'),
              repo,
              (_) {},
              sourceCache,
              (_, __) {},
              (_, __, ___) {},
              connectionFactory: (_) async => from,
            )
            ..deviceID = 'source'
            ..jobs = [job]
            ..assets = [media()];
      final viewer =
          DirectPeers(
              api('viewer'),
              createRepository(),
              (_) {},
              viewerCache,
              (_, bytes) => received.complete(bytes),
              (_, __, ___) {},
              connectionFactory: (_) async => to,
            )
            ..deviceID = 'viewer'
            ..jobs = [job]
            ..assets = [media()];
      await source.tick();
      await viewer.tick();
      await source.tick();
      expect(await received.future.timeout(const Duration(seconds: 2)), png);
      await receipt.future.timeout(const Duration(seconds: 2));
      expect(
        (ThumbnailCache(browserStorage, fail)..load('viewer')).get(media()),
        png,
      );
      expect(
        from.channel!.frames
            .where((f) => f.isBinary)
            .every((f) => f.binary.length <= 16384),
        isTrue,
      );
      expect(
        requests.every(
          (r) =>
              r.url.path == '/api/signals' ||
              r.url.path == '/api/transfers/thumb',
        ),
        isTrue,
      );
      expect(
        requests.every((r) => !r.body.contains(base64Encode(png))),
        isTrue,
      );
      await source.close();
      await viewer.close();
    },
  );
}
