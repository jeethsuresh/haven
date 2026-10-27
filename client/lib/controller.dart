import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';
import 'api.dart';
import 'local.dart';
import 'model.dart';
import 'peer.dart';

class HavenController extends ChangeNotifier {
  final HavenApi api;
  final LocalRepository local;
  late final DirectPeers peers;
  List<MediaAsset> assets = [];
  List<Json> devices = [], transfers = [];
  Json config = {};
  String deviceID = '',
      name = 'This device',
      account = '',
      message = 'Connecting to Haven…';
  List<String> roles = ['viewer'];
  bool ready = false,
      loading = true,
      busy = false,
      _ticking = false,
      _scanning = false,
      _disposed = false;
  Timer? _timer;
  DateTime _heartbeat = DateTime(2000), _lastScan = DateTime(2000);
  HavenController({HavenApi? api, LocalRepository? local})
    : api = api ?? HavenApi(),
      local = local ?? createRepository() {
    peers = DirectPeers(this.api, this.local, report);
  }
  bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get isDesktop => !kIsWeb && !isAndroid;
  String get platform => kIsWeb
      ? 'web'
      : isAndroid
      ? 'android'
      : defaultTargetPlatform.name;
  void changed() {
    if (!_disposed) notifyListeners();
  }

  void report(String text) {
    message = text;
    changed();
  }

  Future<void> initialize() async {
    try {
      await api.restore();
      config = await api.request('GET', '/api/config');
      await connect();
    } on ApiError catch (e) {
      if (e.status != 401) {
        report('$e');
      } else {
        message = 'Your files. Your devices.';
      }
    } catch (e) {
      report('Backend unavailable: $e');
    } finally {
      loading = false;
      changed();
    }
  }

  Future<void> connect() async {
    final me = await api.request('GET', '/api/me') as Json;
    account = me['account'];
    deviceID = me['device_id'];
    await local.load(
      sha256.convert(utf8.encode('${api.base}|$account')).toString(),
    );
    if (deviceID.isEmpty) {
      name = kIsWeb
          ? 'Web viewer'
          : isAndroid
          ? 'Android phone'
          : 'Desktop';
      await configure(['viewer']);
    }
    ready = true;
    await refresh();
    peers.deviceID = deviceID;
    peers.stun = List<String>.from(config['stun_urls'] ?? []);
    _timer?.cancel();
    _timer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(tick()),
    );
    report('Connected. Originals move directly between your devices.');
  }

  Future<void> signIn({bool development = false}) async {
    busy = true;
    changed();
    try {
      if (development) {
        final result = await api.request('POST', '/api/dev/login');
        await api.setToken(result['token']);
        await connect();
      } else if (kIsWeb) {
        await launchUrl(
          Uri.parse('${api.base}/auth/gravitas/start'),
          webOnlyWindowName: '_self',
        );
      } else {
        final random = Random.secure();
        final verifier = base64UrlEncode(
          List<int>.generate(32, (_) => random.nextInt(256)),
        ).replaceAll('=', '');
        final challenge = base64UrlEncode(
          sha256.convert(utf8.encode(verifier)).bytes,
        ).replaceAll('=', '');
        final request = await api.request('POST', '/api/auth/native/start', {
          'challenge': challenge,
        });
        if (!await launchUrl(
          Uri.parse(request['approval_url']),
          mode: LaunchMode.externalApplication,
        )) {
          throw StateError('Could not open sign-in browser');
        }
        report('Finish signing in with Gravitas in your browser.');
        for (var attempt = 0; attempt < 200; attempt++) {
          await Future<void>.delayed(const Duration(seconds: 3));
          if (_disposed) return;
          final result = await api.request('POST', '/api/auth/native/poll', {
            'id': request['id'],
            'verifier': verifier,
          });
          if (result['token'] != null) {
            await api.setToken(result['token']);
            await connect();
            return;
          }
        }
        throw StateError('Sign-in expired. Start again.');
      }
    } catch (e) {
      report('$e');
    } finally {
      busy = false;
      changed();
    }
  }

  Future<void> logout() async {
    _timer?.cancel();
    await peers.close();
    try {
      await api.request('POST', '/api/auth/logout');
    } finally {
      await api.setToken(null);
      ready = false;
      assets = [];
      devices = [];
      transfers = [];
      deviceID = '';
      report('Signed out. Local files are retained.');
    }
  }

  Future<void> configure(List<String> next) async {
    if (next.contains('sink') && local.root.isEmpty) {
      throw StateError('Choose a repository folder first.');
    }
    final d =
        await api.request('POST', '/api/devices', {
              'name': name,
              'platform': platform,
              'roles': next,
            })
            as Json;
    deviceID = d['id'];
    roles = List<String>.from(d['roles']);
    peers.deviceID = deviceID;
    if (!roles.contains('source') && !roles.contains('sink')) {
      await peers.close();
    }
    changed();
  }

  Future<void> chooseRoot({bool media = false}) async {
    if (roles.contains('sink')) {
      throw StateError('Disable sink mode before changing folders.');
    }
    final selected = await local.chooseDirectory();
    if (selected == null) return;
    if (media) {
      local.mediaRoot = selected;
    } else {
      local.root = selected;
    }
    await local.save();
    changed();
  }

  Future<void> refresh() async {
    final raw = await api.request('GET', '/api/assets') as List;
    assets = raw.map((j) => MediaAsset(j['asset'], j['sink_copies'])).toList()
      ..sort(
        (a, b) =>
            (b.data['captured'] as int).compareTo(a.data['captured'] as int),
      );
    devices = List<Json>.from(await api.request('GET', '/api/devices'));
    transfers = List<Json>.from(await api.request('GET', '/api/transfers'));
    for (final device in devices) {
      if (device['id'] == deviceID) {
        name = device['name'];
        roles = List<String>.from(device['roles']);
      }
    }
    peers.assets = assets;
    peers.jobs = transfers;
    changed();
  }

  Future<void> tick() async {
    if (_ticking || _scanning || !ready || _disposed) return;
    _ticking = true;
    try {
      if (DateTime.now().difference(_heartbeat) > const Duration(seconds: 15)) {
        await api.request('POST', '/api/devices/heartbeat');
        _heartbeat = DateTime.now();
      }
      if (!kIsWeb &&
          DateTime.now().difference(_lastScan) > const Duration(seconds: 60)) {
        _lastScan = DateTime.now();
        if (roles.contains('sink')) {
          await publishEntries(await local.scanRoot());
        }
        if (isAndroid && roles.contains('source')) {
          await publishEntries(await local.gallery());
        }
      }
      await refresh();
      if (!kIsWeb) await peers.tick();
    } on ApiError catch (e) {
      if (e.status == 401) {
        _timer?.cancel();
        await peers.close();
        ready = false;
        report('Session ended. Sign in again; your local files are retained.');
      } else {
        await peers.close();
        report('$e');
      }
    } catch (e) {
      report('$e');
    } finally {
      _ticking = false;
    }
  }

  Future<void> scan({bool pick = false}) async {
    if (_scanning || _ticking) return;
    _scanning = true;
    busy = true;
    changed();
    try {
      if (!roles.contains('source') && !roles.contains('sink')) {
        throw StateError('Enable source or sink mode on this device first.');
      }
      final entries = pick
          ? await local.pickFiles()
          : roles.contains('source')
          ? await local.gallery()
          : await local.scanRoot();
      await publishEntries(entries);
      await refresh();
      report('Scan complete. ${entries.length} files checked.');
    } catch (e) {
      report('$e');
    } finally {
      _scanning = false;
      busy = false;
      changed();
    }
  }

  String _clean(String name) => name
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '_');
  String _logicalPath(LocalEntry e) {
    final ref = e.ref.replaceAll('\\', '/');
    final root = local.root.replaceAll('\\', '/');
    final media = local.mediaRoot.replaceAll('\\', '/');
    if (media.isNotEmpty && ref.startsWith('$media/')) {
      return 'Media/${ref.substring(media.length + 1)}';
    }
    if (root.isNotEmpty && ref.startsWith('$root/')) {
      return ref.substring(root.length + 1);
    }
    if (e.mime.startsWith('image/') ||
        e.mime.startsWith('video/') ||
        e.mime.startsWith('audio/')) {
      final date = DateTime.fromMillisecondsSinceEpoch(
        e.captured * 1000,
      ).toUtc();
      return 'Media/${date.year}/${date.month.toString().padLeft(2, '0')}/${_clean(e.name)}';
    }
    return 'Files/${_clean(e.name)}';
  }

  Future<void> publishEntries(List<LocalEntry> entries) async {
    for (var e in entries) {
      final matches = local.records.values
          .where((v) => v.entry.ref == e.ref)
          .toList();
      final previous = matches.isEmpty ? null : matches.first;
      if (previous != null &&
          previous.entry.size == e.size &&
          previous.entry.modified == e.modified) {
        continue;
      }
      final hash = await local.digest(e);
      if (previous?.asset.hash == hash) {
        local.records[previous!.asset.id] = LocalRecord(previous.asset, e);
        await local.save();
        continue;
      }
      final path = previous?.asset.path ?? _logicalPath(e);
      final kind = path.startsWith('Media/')
          ? 'media'
          : path.startsWith('Structured/Contacts/')
          ? 'contact'
          : path.startsWith('Structured/Notes/')
          ? 'note'
          : 'file';
      report('Indexing ${e.name}…');
      final asset = MediaAsset(
        await api.request('POST', '/api/assets', {
          'id': previous?.asset.id ?? '',
          'base': previous?.asset.revision ?? '',
          'kind': kind,
          'path': path,
          'mime': e.mime,
          'sha256': hash,
          'size': e.size,
          'captured': e.captured,
        }),
      );
      if (asset.data['conflict_of'] != null) {
        e = await local.relocate(e, asset);
        if (previous != null) local.records.remove(previous.asset.id);
        report('Preserved a conflict copy: ${asset.name}');
      }
      local.records[asset.id] = LocalRecord(asset, e);
      await local.save();
      final thumbnail = await local.thumbnail(e);
      if (thumbnail != null) {
        try {
          await api.uploadThumbnail(asset.id, thumbnail);
        } catch (error) {
          report('$error');
        }
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(peers.close());
    api.client.close();
    super.dispose();
  }
}
