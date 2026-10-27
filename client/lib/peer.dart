import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'api.dart';
import 'model.dart';

/// Only metadata and SDP/ICE use the server. Original bytes exclusively use
/// ordered, reliable, DTLS-encrypted SCTP data channels between devices.
class DirectPeers {
  final HavenApi api;
  final LocalRepository local;
  final void Function(String) report;
  final Map<String, _Peer> _peers = {};
  final Map<String, DateTime> _attempts = {};
  final Map<String, List<RTCIceCandidate>> _early = {};
  List<String> stun = [];
  String deviceID = '';
  List<Json> jobs = [];
  List<MediaAsset> assets = [];
  int cursor = 0;
  DirectPeers(this.api, this.local, this.report);
  Future<void> close() async {
    for (final p in _peers.values.toList()) {
      await p.close();
    }
    _peers.clear();
    _early.clear();
    _attempts.clear();
    cursor = 0;
  }

  MediaAsset? _asset(Json job) {
    for (final asset in assets) {
      if (asset.id == job['asset_id']) {
        final revisions = (asset.data['revisions'] as List)
            .where((v) => v['id'] == job['revision_id'])
            .toList();
        if (revisions.isNotEmpty) {
          return MediaAsset({...asset.data, 'revisions': revisions});
        }
      }
    }
    return null;
  }

  Future<_Peer> _make(Json job, bool initiator, {String? attempt}) async {
    final asset = _asset(job);
    if (asset == null) throw StateError('Transfer manifest unavailable');
    final config = {
      'iceServers': [
        for (final url in stun) {'urls': url},
      ],
      'sdpSemantics': 'unified-plan',
    };
    if (stun.any((s) => !s.startsWith('stun:'))) {
      throw StateError('TURN configuration rejected');
    }
    final pc = await createPeerConnection(config);
    late _Peer peer;
    final generation =
        attempt ??
        '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
    peer = _Peer(
      api,
      local,
      job,
      asset,
      pc,
      initiator,
      generation,
      report,
      () async {
        if (identical(_peers[job['id']], peer)) _peers.remove(job['id']);
      },
    );
    _peers[job['id']] = peer;
    pc.onIceCandidate = (c) {
      if (c.candidate?.isNotEmpty == true &&
          !c.candidate!.contains('typ relay')) {
        unawaited(
          peer
              .signal('candidate', c.toMap())
              .catchError((Object e) => report('$e')),
        );
      }
    };
    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        unawaited(
          peer.fail(
            'Waiting for a direct route. Try the same Wi-Fi or a reachable network.',
          ),
        );
      }
    };
    pc.onDataChannel = peer.attach;
    if (initiator) {
      peer.attach(
        await pc.createDataChannel(
          'haven-v1',
          RTCDataChannelInit()..ordered = true,
        ),
      );
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await peer.signal('offer', offer.toMap());
    }
    return peer;
  }

  Future<void> tick() async {
    for (final p in _peers.values.toList()) {
      final valid = jobs.any(
        (j) =>
            j['id'] == p.job['id'] &&
            j['from'] == p.job['from'] &&
            j['to'] == p.job['to'] &&
            j['status'] != 'superseded' &&
            j['status'] != 'complete',
      );
      if (!valid) {
        await p.close();
      } else if (DateTime.now().difference(p.activity) >
          const Duration(seconds: 45)) {
        await p.fail('Waiting for a direct route; transfer will retry.');
      }
    }
    final inbox =
        await api.request('GET', '/api/signals?after=$cursor') as Json;
    for (final raw in inbox['signals'] as List) {
      final signal = raw as Json;
      final matches = jobs
          .where(
            (j) =>
                j['id'] == signal['transfer_id'] &&
                j['status'] != 'superseded' &&
                j['status'] != 'complete',
          )
          .toList();
      if (matches.isEmpty) continue;
      final job = matches.first;
      var peer = _peers[job['id']];
      final data = signal['data'] as Json;
      final generation = data['attempt'] as String?;
      if (generation == null || generation.length > 100) continue;
      final candidateKey = '${job['id']}:$generation';
      if (signal['type'] == 'offer') {
        if (job['to'] != deviceID || local.root.isEmpty) continue;
        if (peer?.attempt == generation) continue;
        if (peer != null) await peer.close();
        peer = await _make(job, false, attempt: generation);
        await peer.pc.setRemoteDescription(
          RTCSessionDescription(data['sdp'], 'offer'),
        );
        peer.remoteSet = true;
        for (final c in _early.remove(candidateKey) ?? <RTCIceCandidate>[]) {
          await peer.pc.addCandidate(c);
        }
        final answer = await peer.pc.createAnswer();
        await peer.pc.setLocalDescription(answer);
        await peer.signal('answer', answer.toMap());
      } else if (signal['type'] == 'answer' &&
          peer != null &&
          peer.attempt == generation &&
          !peer.remoteSet) {
        await peer.pc.setRemoteDescription(
          RTCSessionDescription(data['sdp'], 'answer'),
        );
        peer.remoteSet = true;
        for (final c in _early.remove(candidateKey) ?? <RTCIceCandidate>[]) {
          await peer.pc.addCandidate(c);
        }
      } else if (signal['type'] == 'candidate') {
        final candidate = RTCIceCandidate(
          data['candidate'],
          data['sdpMid'],
          data['sdpMLineIndex'],
        );
        if (candidate.candidate?.contains('typ relay') == true) continue;
        if (peer != null && peer.attempt != generation) continue;
        if (peer?.remoteSet == true) {
          await peer!.pc.addCandidate(candidate);
        } else {
          if (_early.length > 256) _early.remove(_early.keys.first);
          final queue = _early.putIfAbsent(candidateKey, () => []);
          if (queue.length < 128) queue.add(candidate);
        }
      }
    }
    cursor = inbox['cursor'] as int;
    for (final job in jobs) {
      if (job['from'] != deviceID ||
          job['status'] == 'complete' ||
          job['status'] == 'superseded' ||
          _peers.containsKey(job['id'])) {
        continue;
      }
      final last = _attempts[job['id']];
      if (last != null &&
          DateTime.now().difference(last) < const Duration(seconds: 60)) {
        continue;
      }
      if (_peers.values.where((p) => p.initiator).length >= 2) break;
      final asset = _asset(job);
      final record = local.records[job['asset_id']];
      if (asset == null ||
          record == null ||
          record.asset.revision != asset.revision) {
        continue;
      }
      _attempts[job['id']] = DateTime.now();
      await api.request('POST', '/api/transfers/${job['id']}', {
        'status': 'connecting',
      });
      await _make(job, true);
    }
  }
}

class _Peer {
  final HavenApi api;
  final LocalRepository local;
  final Json job;
  final MediaAsset asset;
  final RTCPeerConnection pc;
  final bool initiator;
  final String attempt;
  final void Function(String) report;
  final Future<void> Function() onClose;
  RTCDataChannel? channel;
  bool remoteSet = false, closed = false, _sending = false, _done = false;
  int _sent = 0, _acked = 0, _received = 0;
  DateTime activity = DateTime.now();
  Future<void> _messages = Future.value();
  _Peer(
    this.api,
    this.local,
    this.job,
    this.asset,
    this.pc,
    this.initiator,
    this.attempt,
    this.report,
    this.onClose,
  );
  Future<void> signal(String type, Json data) async {
    if (!closed) {
      await api.request('POST', '/api/signals', {
        'transfer_id': job['id'],
        'type': type,
        'data': {...data, 'attempt': attempt},
      });
    }
  }

  Future<void> control(Json value) async {
    if (!closed) await channel!.send(RTCDataChannelMessage(jsonEncode(value)));
  }

  void attach(RTCDataChannel ch) {
    channel = ch;
    ch.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen && initiator) {
        unawaited(
          control({
            'type': 'start',
            'revision': asset.revision,
            'sha256': asset.hash,
            'size': asset.size,
          }).catchError((Object e) => fail('$e')),
        );
      }
    };
    ch.onMessage = (message) {
      _messages = _messages
          .then((_) => _message(message))
          .catchError((Object e) => fail('$e'));
    };
  }

  Future<void> _message(RTCDataChannelMessage message) async {
    if (closed) return;
    activity = DateTime.now();
    if (message.isBinary) {
      if (initiator || message.binary.length > 16384) {
        throw StateError('Unexpected data frame');
      }
      await local.append(asset, _received, message.binary);
      _received += message.binary.length;
      await control({'type': 'ack', 'offset': _received});
      return;
    }
    final data = jsonDecode(message.text) as Json;
    switch (data['type']) {
      case 'start':
        if (initiator ||
            data['revision'] != asset.revision ||
            data['sha256'] != asset.hash ||
            data['size'] != asset.size) {
          throw StateError('Manifest mismatch');
        }
        _received = await local.partialLength(asset);
        if (_received > asset.size) throw StateError('Invalid partial length');
        if (_received == 0) await local.append(asset, 0, Uint8List(0));
        await api.request('POST', '/api/transfers/${job['id']}', {
          'status': 'transferring',
        });
        await control({'type': 'ready', 'offset': _received});
      case 'ready':
        if (!initiator) throw StateError('Unexpected ready');
        _acked = data['offset'] as int;
        _sent = _acked;
        if (_acked < 0 || _acked > asset.size) {
          throw StateError('Invalid resume offset');
        }
        await _pump();
      case 'ack':
        final offset = data['offset'] as int;
        if (!initiator || offset < _acked || offset > _sent) {
          throw StateError('Invalid acknowledgement');
        }
        _acked = offset;
        await _pump();
      case 'done':
        if (initiator || _received != asset.size) {
          throw StateError('Incomplete transfer');
        }
        final entry = await local.commit(asset);
        local.records[asset.id] = LocalRecord(asset, entry);
        await local.save();
        await api.request('POST', '/api/transfers/${job['id']}', {
          'status': 'complete',
          'sha256': asset.hash,
        });
        report('Verified ${asset.name}');
        await control({'type': 'complete'});
        await close();
      case 'complete':
        await close();
      case 'error':
        await fail('Peer: ${data['message']}');
      default:
        throw StateError('Unknown transfer frame');
    }
  }

  Future<void> _pump() async {
    if (_sending || closed) return;
    _sending = true;
    try {
      final record = local.records[asset.id];
      if (record == null || record.asset.revision != asset.revision) {
        throw StateError('Original revision unavailable');
      }
      while (!closed && _sent < asset.size && _sent - _acked < 262144) {
        final bytes = await local.read(
          record.entry,
          _sent,
          min(16384, asset.size - _sent),
        );
        if (bytes.isEmpty) throw StateError('Original changed during transfer');
        _sent += bytes.length;
        activity = DateTime.now();
        await channel!.send(RTCDataChannelMessage.fromBinary(bytes));
      }
      if (!closed && _acked == asset.size && !_done) {
        _done = true;
        await control({'type': 'done'});
      }
    } finally {
      _sending = false;
    }
  }

  Future<void> fail(String message) async {
    if (closed) return;
    report(message);
    try {
      await api.request('POST', '/api/transfers/${job['id']}', {
        'status': 'waiting_for_peer',
      });
    } catch (_) {}
    await close();
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    try {
      await channel?.close();
      await pc.close();
    } finally {
      await onClose();
    }
  }
}
