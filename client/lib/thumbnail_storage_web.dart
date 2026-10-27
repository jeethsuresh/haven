import 'package:web/web.dart' as web;
import 'thumbnail_cache.dart';

ThumbnailStorage createThumbnailStorage() => _BrowserThumbnails();

class _BrowserThumbnails implements ThumbnailStorage {
  @override
  String? read(String key) => web.window.localStorage.getItem(key);
  @override
  void write(String key, String value) =>
      web.window.localStorage.setItem(key, value);
  @override
  void remove(String key) => web.window.localStorage.removeItem(key);
}
