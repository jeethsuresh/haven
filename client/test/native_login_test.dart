import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:haven/api.dart';
import 'package:haven/controller.dart';
import 'package:haven/local_stub.dart';
import 'package:haven/model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });
  test(
    'Android browser handoff redeems PKCE and persists a usable device session',
    () async {
      var challenge = '', polls = 0;
      final protected = <String>[];
      final api = HavenApi(
        base: 'https://haven.example',
        client: MockClient((request) async {
          final body = request.body.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(request.body) as Json;
          switch (request.url.path) {
            case '/api/auth/native/start':
              expect(body['platform'], 'android');
              challenge = body['challenge'];
              return http.Response(
                jsonEncode({
                  'id': 'login-request',
                  'approval_url':
                      'https://haven.example/auth/gravitas/start?next=%2Fnative%2Fcomplete%3Fid%3Dlogin-request',
                }),
                200,
              );
            case '/api/auth/native/poll':
              expect(body['id'], 'login-request');
              expect(
                base64UrlEncode(
                  sha256.convert(utf8.encode(body['verifier'])).bytes,
                ).replaceAll('=', ''),
                challenge,
              );
              return ++polls == 1
                  ? http.Response('{"status":"pending"}', 202)
                  : http.Response('{"token":"native-session"}', 200);
            default:
              expect(request.headers['Authorization'], 'Bearer native-session');
              protected.add(request.url.path);
              if (request.url.path == '/api/me') {
                return http.Response(
                  '{"account":"account","device_id":""}',
                  200,
                );
              }
              if (request.url.path == '/api/devices' &&
                  request.method == 'POST') {
                expect(body['platform'], 'android');
                expect(body['roles'], ['viewer']);
                return http.Response(
                  '{"id":"android-device","roles":["viewer"]}',
                  200,
                );
              }
              if (request.url.path == '/api/devices/heartbeat') {
                return http.Response('{"ok":true}', 200);
              }
              return http.Response('[]', 200);
          }
        }),
      );
      var opened = false;
      final controller = HavenController(
        api: api,
        local: createRepository(),
        openNativeBrowser: (uri) async {
          expect(uri.origin, 'https://haven.example');
          expect(uri.path, '/auth/gravitas/start');
          opened = true;
          return true;
        },
      );
      addTearDown(controller.dispose);
      await controller.signIn();
      expect(opened, isTrue);
      expect(polls, 2);
      expect(controller.ready, isTrue);
      expect(controller.deviceID, 'android-device');
      expect(controller.busy, isFalse);
      expect(
        protected,
        containsAll(['/api/me', '/api/devices', '/api/assets', '/api/reports']),
      );
      expect(
        await const FlutterSecureStorage().read(
          key: 'haven:https://haven.example',
        ),
        'native-session',
      );
    },
  );
  test('native platform names match the backend role protocol', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final controller = HavenController(local: createRepository());
    expect(controller.platform, 'macos');
    controller.dispose();
  });
  test(
    'failed Android browser launch leaves the app signed out and retryable',
    () async {
      var calls = 0;
      final api = HavenApi(
        base: 'https://haven.example',
        client: MockClient((request) async {
          calls++;
          expect(request.url.path, '/api/auth/native/start');
          return http.Response(
            '{"id":"request","approval_url":"https://haven.example/auth/gravitas/start"}',
            200,
          );
        }),
      );
      final controller = HavenController(
        api: api,
        local: createRepository(),
        openNativeBrowser: (_) async => false,
      );
      addTearDown(controller.dispose);
      await controller.signIn();
      expect(calls, 1);
      expect(controller.ready, isFalse);
      expect(controller.busy, isFalse);
      expect(controller.message, contains('Could not open sign-in browser'));
      expect(api.token, isNull);
    },
  );
}
