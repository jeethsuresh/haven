import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'model.dart';

class ApiError implements Exception {
  final int status;
  final String message;
  ApiError(this.status, this.message);
  @override
  String toString() => message.replaceAll('_', ' ');
}

class HavenApi {
  static const configured = String.fromEnvironment('HAVEN_BACKEND');
  final String base;
  final http.Client client;
  String? token;
  HavenApi({String? base, http.Client? client})
    : base =
          base ??
          (configured.isNotEmpty
              ? configured
              : (kIsWeb ? Uri.base.origin : 'http://127.0.0.1:8090')),
      client = client ?? http.Client();
  Map<String, String> get headers => {
    'X-Haven-CSRF': '1',
    if (token != null) 'Authorization': 'Bearer $token',
  };
  Future<void> restore() async {
    if (!kIsWeb) {
      token = await const FlutterSecureStorage(
        mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      ).read(key: 'haven:$base');
    }
  }

  Future<void> setToken(String? value) async {
    token = value;
    if (!kIsWeb) {
      if (value == null) {
        await const FlutterSecureStorage(
          mOptions: MacOsOptions(usesDataProtectionKeychain: false),
        ).delete(key: 'haven:$base');
      } else {
        await const FlutterSecureStorage(
          mOptions: MacOsOptions(usesDataProtectionKeychain: false),
        ).write(key: 'haven:$base', value: value);
      }
    }
  }

  // The browser may outlive the Android process. Keep its PKCE verifier in
  // encrypted storage until the device session has been saved or login expires.
  Future<Json?> restoreNativeLogin() async {
    if (kIsWeb) return null;
    final raw = await const FlutterSecureStorage(
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    ).read(key: 'haven:$base:pending-login');
    if (raw == null) return null;
    try {
      final pending = jsonDecode(raw) as Json;
      if (pending['id'] is String &&
          (pending['id'] as String).isNotEmpty &&
          pending['verifier'] is String &&
          RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(pending['verifier']) &&
          pending['expires'] is int &&
          DateTime.now().millisecondsSinceEpoch < pending['expires']) {
        return pending;
      }
    } on FormatException {
      // Invalid or older state cannot be used to resume a sign-in.
    } on TypeError {
      // Treat an invalid saved shape as an expired sign-in.
    }
    await saveNativeLogin(null);
    return null;
  }

  Future<void> saveNativeLogin(Json? pending) async {
    if (kIsWeb) return;
    const storage = FlutterSecureStorage(
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    );
    final key = 'haven:$base:pending-login';
    if (pending == null) {
      await storage.delete(key: key);
    } else {
      await storage.write(key: key, value: jsonEncode(pending));
    }
  }

  Future<dynamic> request(String method, String path, [Json? body]) async {
    final req = http.Request(method, Uri.parse('$base$path'))
      ..headers.addAll({...headers, 'Content-Type': 'application/json'});
    if (body != null) req.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await client.send(req).timeout(const Duration(seconds: 20)),
    );
    final value = response.body.isEmpty ? null : jsonDecode(response.body);
    if (response.statusCode >= 400) {
      throw ApiError(response.statusCode, value?['error'] ?? 'Request failed');
    }
    return value;
  }
}
