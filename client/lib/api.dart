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
