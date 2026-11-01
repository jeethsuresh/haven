import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:haven/api.dart';
import 'package:haven/controller.dart';
import 'package:haven/desktop_store_broker.dart';
import 'package:haven/local_stub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'Haven signs in with Store code and only stores its own device session',
    () async {
      String? challenge;
      var browsers = 0;
      final api = HavenApi(
        base: 'https://haven.example',
        client: MockClient((r) async {
          if (r.url.path == '/api/auth/native/broker') {
            final b = jsonDecode(r.body) as Map;
            expect(
              base64UrlEncode(
                sha256.convert(utf8.encode(b['code_verifier'] as String)).bytes,
              ).replaceAll('=', ''),
              challenge,
            );
            expect(b['sub'], 'alice');
            expect(b['session_id'], 'family');
            return http.Response('{"token":"haven-device-session"}', 200);
          }
          expect(r.headers['Authorization'], 'Bearer haven-device-session');
          if (r.url.path == '/api/me') {
            return http.Response('{"account":"alice","device_id":""}', 200);
          }
          if (r.url.path == '/api/devices' && r.method == 'POST') {
            return http.Response(
              '{"id":"desktop-device","roles":["viewer"]}',
              200,
            );
          }
          if (r.url.path == '/api/devices/heartbeat') {
            return http.Response('{"ok":true}', 200);
          }
          return http.Response('[]', 200);
        }),
      );
      final controller = HavenController(
        api: api,
        local: createRepository(),
        brokerAuthorize: (origin, proof, state) async {
          expect(origin, api.base);
          challenge = proof;
          expect(state.length, 43);
          return {'code': 'c' * 43, 'sub': 'alice', 'session_id': 'family'};
        },
        openNativeBrowser: (_) async {
          browsers++;
          return false;
        },
      );
      addTearDown(controller.dispose);
      await controller.signIn();
      expect(controller.ready, true);
      expect(browsers, 0);
      expect(
        await const FlutterSecureStorage().read(key: 'haven:${api.base}'),
        'haven-device-session',
      );
    },
  );
  test(
    'cancelling Store sign-in never opens browser and logout rejects late exchange',
    () async {
      var browsers = 0;
      final cancelled = HavenController(
        local: createRepository(),
        brokerAuthorize: (_, _, _) async => throw StoreSignInCancelled(),
        openNativeBrowser: (_) async {
          browsers++;
          return true;
        },
      );
      addTearDown(cancelled.dispose);
      await cancelled.signIn();
      expect(cancelled.ready, false);
      expect(browsers, 0);
      final response = Completer<http.Response>(),
          requested = Completer<void>();
      final api = HavenApi(
        base: 'https://haven.example',
        client: MockClient((r) {
          if (r.url.path == '/api/auth/logout') {
            return Future.value(http.Response('', 204));
          }
          requested.complete();
          return response.future;
        }),
      );
      final pending = HavenController(
        api: api,
        local: createRepository(),
        brokerAuthorize: (_, _, _) async => {
          'code': 'c' * 43,
          'sub': 'alice',
          'session_id': 'family',
        },
      );
      addTearDown(pending.dispose);
      final login = pending.signIn();
      await requested.future;
      await pending.logout();
      response.complete(http.Response('{"token":"late"}', 200));
      await login;
      expect(api.token, null);
      expect(pending.ready, false);
      expect(
        await const FlutterSecureStorage().read(key: 'haven:${api.base}'),
        null,
      );
    },
  );
}
