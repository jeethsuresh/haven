import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'model.dart';

abstract class ThumbnailStorage {
  String? read(String key);
  void write(String key, String value);
  void remove(String key);
}

class MemoryThumbnailStorage implements ThumbnailStorage {
  final Map<String, String> values = {};
  @override
  String? read(String key) => values[key];
  @override
  void write(String key, String value) => values[key] = value;
  @override
  void remove(String key) => values.remove(key);
}

/// A bounded, account-scoped cache. Storage failure never routes bytes to HTTP.
class ThumbnailCache {
  final ThumbnailStorage storage;
  final void Function(String) warning;
  final int maxCharacters;
  final Map<String, String> _entries = {};
  String _key = '';
  bool _warned = false;
  ThumbnailCache(this.storage, this.warning, {this.maxCharacters = 1500000});
  String key(MediaAsset asset) => '${asset.id}:${asset.revision}';
  void load(String scope) {
    _entries.clear();
    _warned = false;
    _key = 'haven:thumbnails:v1:$scope';
    try {
      final stored = storage.read(_key);
      if (stored != null && stored.length <= maxCharacters) {
        final data = jsonDecode(stored) as Map<String, dynamic>;
        for (final entry in data.entries) {
          if (entry.value is String &&
              (entry.value as String).length <= 175000) {
            _entries[entry.key] = entry.value as String;
          }
        }
      }
    } catch (_) {
      _warn();
    }
  }

  Uint8List? get(MediaAsset asset) {
    final id = key(asset), value = _entries.remove(key(asset));
    if (value == null) return null;
    try {
      final bytes = base64Decode(value);
      validateThumbnail(bytes);
      _entries[id] = value;
      return bytes;
    } catch (_) {
      return null;
    }
  }

  void put(MediaAsset asset, Uint8List bytes) {
    validateThumbnail(bytes);
    _entries.removeWhere((k, _) => k.startsWith('${asset.id}:'));
    _entries[key(asset)] = base64Encode(bytes);
    while (jsonEncode(_entries).length > maxCharacters && _entries.isNotEmpty) {
      _entries.remove(_entries.keys.first);
    }
    // Retry after evicting older entries if the origin's remaining quota is low.
    while (_entries.isNotEmpty) {
      try {
        storage.write(_key, jsonEncode(_entries));
        return;
      } catch (_) {
        if (_entries.length == 1) {
          _warn();
          return;
        }
        _entries.remove(_entries.keys.first);
      }
    }
  }

  void clear() {
    _entries.clear();
    try {
      storage.remove(_key);
    } catch (_) {
      _warn();
    }
    _key = '';
  }

  void _warn() {
    if (!_warned) {
      warning(
        'Browser thumbnail storage is unavailable or full. Thumbnails remain in memory for this session.',
      );
    }
    _warned = true;
  }
}

/// Validate bounds before an image codec can allocate pixels from peer input.
void validateThumbnail(Uint8List bytes, {String? expectedHash}) {
  if (bytes.isEmpty ||
      bytes.length > 128 << 10 ||
      (expectedHash != null &&
          sha256.convert(bytes).toString() != expectedHash)) {
    throw StateError('Invalid thumbnail length or checksum');
  }
  int width = 0, height = 0;
  final view = ByteData.sublistView(bytes);
  if (bytes.length >= 24 &&
      bytes.take(8).join(',') == '137,80,78,71,13,10,26,10' &&
      ascii.decode(bytes.sublist(12, 16), allowInvalid: true) == 'IHDR') {
    width = view.getUint32(16);
    height = view.getUint32(20);
  } else if (bytes.length > 4 && bytes[0] == 255 && bytes[1] == 216) {
    var offset = 2;
    while (offset + 4 <= bytes.length && bytes[offset] == 255) {
      final marker = bytes[offset + 1];
      if (marker == 255) {
        offset++;
        continue;
      }
      final length = view.getUint16(offset + 2);
      if (length < 2 || offset + 2 + length > bytes.length) break;
      if ([
            192,
            193,
            194,
            195,
            197,
            198,
            199,
            201,
            202,
            203,
            205,
            206,
            207,
          ].contains(marker) &&
          length >= 7) {
        height = view.getUint16(offset + 5);
        width = view.getUint16(offset + 7);
        break;
      }
      offset += 2 + length;
    }
  }
  if (width < 1 || height < 1 || width > 512 || height > 512) {
    throw StateError('Expected a PNG or JPEG thumbnail up to 512 pixels');
  }
}
