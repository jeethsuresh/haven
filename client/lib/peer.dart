import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:crypto/crypto.dart';
import 'thumbnail_cache.dart';
import 'api.dart';
import 'model.dart';

/// Only metadata and SDP/ICE use the server. All file and thumbnail bytes use
/// ordered, reliable, DTLS-encrypted SCTP data channels between devices.
class DirectPeers {
  final HavenApi api;
  final Future<RTCPeerConnection> Function(Map<String, dynamic>)
  connectionFactory;
  final LocalRepository local;
  final void Function(String) report;
  final ThumbnailCache thumbnails;
  final void Function(MediaAsset, Uint8List) receivedThumbnail;
  final void Function(String, String?, String) issue;
  final Map<String, _Peer> _peers = {};
  final Map<String, DateTime> _attempts = {};
  final Map<String, List<RTCIceCandidate>> _early = {};
  List<String> stun = [];
  String deviceID = '';
  List<Json> jobs = [];
  List<MediaAsset> assets = [];
  int cursor = 0;
  DirectPeers(
    this.api,
    this.local,
    this.report,
    this.thumbnails,
    this.receivedThumbnail,
    this.issue, {
    Future<RTCPeerConnection> Function(Map<String, dynamic>)? connectionFactory,
  }) : connectionFactory =
           connectionFactory ?? ((config) => createPeerConnection(config));
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
    final pc = await connectionFactory(config);
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
      thumbnails,
      receivedThumbnail,
      issue,
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
          job['purpose'] == 'thumbnail' ? 'haven-thumbnail-v1' : 'haven-v1',
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
            j['status'] != 'complete' &&
            j['status'] != 'unavailable',
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
                j['status'] != 'complete' &&
                j['status'] != 'unavailable',
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
        if (job['to'] != deviceID ||
            (job['purpose'] != 'thumbnail' && local.root.isEmpty)) {
          continue;
        }
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
          job['status'] == 'unavailable' ||
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
  final ThumbnailCache thumbnails;
  final void Function(MediaAsset, Uint8List) receivedThumbnail;
  final void Function(String, String?, String) issue;
  bool get isThumbnail => job['purpose'] == 'thumbnail';
  Uint8List? _outbound;
  final BytesBuilder _thumbnailBytes = BytesBuilder(copy: false);
  int _total = 0;
  String _hash = '';
  bool _started = false, _ready = false;
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
    this.thumbnails,
    this.receivedThumbnail,
    this.issue,
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
    if (ch.label != (isThumbnail ? 'haven-thumbnail-v1' : 'haven-v1')) {
      unawaited(
        fail(
          'Peer needs a compatible Haven version.',
          unavailable: isThumbnail,
        ),
      );
      return;
    }
    channel = ch;
    ch.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen && initiator) {
        unawaited(
          _start().catchError(
            (Object e) => fail('$e', unavailable: isThumbnail),
          ),
        );
      }
    };
    ch.onMessage = (message) {
      _messages = _messages
          .then((_) => _message(message))
          .catchError((Object e) => fail('$e'));
    };
  }

  Future<void> _start() async {
    _total = asset.size;
    _hash = asset.hash;
    if (isThumbnail) {
      _outbound = thumbnails.get(asset);
      final record = local.records[asset.id];
      _outbound ??= record == null ? null : await local.thumbnail(record.entry);
      if (_outbound == null) {
        throw StateError('Thumbnail unavailable on this device');
      }
      validateThumbnail(_outbound!);
      thumbnails.put(asset, _outbound!);
      _total = _outbound!.length;
      _hash = sha256.convert(_outbound!).toString();
    }
    await control({
      'type': 'start',
      'purpose': isThumbnail ? 'thumbnail' : 'original',
      'revision': asset.revision,
      'sha256': _hash,
      'size': _total,
    });
  }

  Future<void> _message(RTCDataChannelMessage message) async {
    if (closed) return;
    activity = DateTime.now();
    if (message.isBinary) {
      if (initiator ||
          !_started ||
          message.binary.length > 16384 ||
          _received + message.binary.length > _total) {
        throw StateError('Unexpected data frame');
      }
      if (isThumbnail) {
        _thumbnailBytes.add(message.binary);
      } else {
        await local.append(asset, _received, message.binary);
      }
      _received += message.binary.length;
      await control({'type': 'ack', 'offset': _received});
      return;
    }
    final data = jsonDecode(message.text) as Json;
    switch (data['type']) {
      case 'start':
        if (initiator || _started || data['revision'] != asset.revision) {
          throw StateError('Manifest mismatch');
        }
        if (isThumbnail) {
          if (data['purpose'] != 'thumbnail' ||
              data['size'] is! int ||
              data['size'] < 1 ||
              data['size'] > 128 << 10 ||
              data['sha256'] is! String ||
              !RegExp(r'^[a-f0-9]{64}$').hasMatch(data['sha256'])) {
            throw StateError('Invalid thumbnail descriptor');
          }
          _total = data['size'];
          _hash = data['sha256'];
          _received = 0;
        } else {
          if (data['sha256'] != asset.hash || data['size'] != asset.size) {
            throw StateError('Manifest mismatch');
          }
          _total = asset.size;
          _hash = asset.hash;
          _received = await local.partialLength(asset);
          if (_received > asset.size) {
            throw StateError('Invalid partial length');
          }
          if (_received == 0) await local.append(asset, 0, Uint8List(0));
        }
        _started = true;
        await api.request('POST', '/api/transfers/${job['id']}', {
          'status': 'transferring',
        });
        await control({'type': 'ready', 'offset': _received});
      case 'ready':
        if (!initiator || _ready) throw StateError('Unexpected ready');
        _ready = true;
        _acked = data['offset'] as int;
        _sent = _acked;
        if (_acked < 0 || _acked > _total || (isThumbnail && _acked != 0)) {
          throw StateError('Invalid resume offset');
        }
        await _pump();
      case 'ack':
        final offset = data['offset'] as int;
        if (!initiator || !_ready || offset < _acked || offset > _sent) {
          throw StateError('Invalid acknowledgement');
        }
        _acked = offset;
        await _pump();
      case 'done':
        if (initiator || !_started || _received != _total) {
          throw StateError('Incomplete transfer');
        }
        if (isThumbnail) {
          final bytes = _thumbnailBytes.takeBytes();
          validateThumbnail(bytes, expectedHash: _hash);
          thumbnails.put(asset, bytes);
          receivedThumbnail(asset, bytes);
        } else {
          final entry = await local.commit(asset);
          local.records[asset.id] = LocalRecord(asset, entry);
          await local.save();
        }
        await api.request('POST', '/api/transfers/${job['id']}', {
          'status': 'complete',
          'sha256': _hash,
        });
        issue('transfer:${job['id']}', null, asset.id);
        if (!isThumbnail) report('Verified ${asset.name}');
        await control({'type': 'complete'});
        await close();
      case 'complete':
        issue('transfer:${job['id']}', null, asset.id);
        await close();
      case 'error':
        await fail('Peer: ${data['message']}');
      default:
        throw StateError('Unknown transfer frame');
    }
  }

  Future<void> _pump() async {
    if (_sending || closed || !_ready) return;
    _sending = true;
    try {
      final record = local.records[asset.id];
      if (!isThumbnail &&
          (record == null || record.asset.revision != asset.revision)) {
        throw StateError('Original revision unavailable');
      }
      while (!closed && _sent < _total && _sent - _acked < 262144) {
        final length = min(16384, _total - _sent);
        final bytes = isThumbnail
            ? Uint8List.sublistView(_outbound!, _sent, _sent + length)
            : await local.read(record!.entry, _sent, length);
        if (bytes.isEmpty) throw StateError('Original changed during transfer');
        _sent += bytes.length;
        activity = DateTime.now();
        await channel!.send(RTCDataChannelMessage.fromBinary(bytes));
      }
      if (!closed && _acked == _total && !_done) {
        _done = true;
        await control({'type': 'done'});
      }
    } finally {
      _sending = false;
    }
  }

  Future<void> fail(String message, {bool unavailable = false}) async {
    if (closed) return;
    if (!isThumbnail) {
      report(message);
      issue('transfer:${job["id"]}', message, asset.id);
    }
    try {
      await api.request('POST', '/api/transfers/${job['id']}', {
        'status': unavailable ? 'unavailable' : 'waiting_for_peer',
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
