import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/api.dart';
import 'package:haven/controller.dart';
import 'package:haven/local_stub.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const origin = 'https://haven.example';

http.Response connectedResponse(http.Request request) {
  if (request.url.path == '/api/config') {
    return http.Response('{"dev":false,"stun_urls":[]}', 200);
  }
  if (request.headers['Authorization'] != 'Bearer device-session') {
    return http.Response('{"error":"sign_in_required"}', 401);
  }
  if (request.url.path == '/api/me') {
    return http.Response('{"account":"alice","device_id":"phone"}', 200);
  }
  if (request.url.path == '/api/devices/heartbeat') {
    return http.Response('{}', 200);
  }
  return http.Response('[]', 200);
}

Map<String, dynamic> pending({int? expires}) => {
  'id': 'request',
  'verifier': 'v' * 43,
  'expires':
      expires ??
      DateTime.now().add(const Duration(minutes: 10)).millisecondsSinceEpoch,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    FlutterSecureStorage.setMockInitialValues({});
  });
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test(
    'Android process restart resumes the original browser approval',
    () async {
      String? challenge;
      final firstApi = HavenApi(
        base: origin,
        client: MockClient((request) async {
          expect(request.url.path, '/api/auth/native/start');
          challenge = jsonDecode(request.body)['challenge'];
          return http.Response(
            '{"id":"request","approval_url":"$origin/auth/gravitas/start"}',
            200,
          );
        }),
      );
      late HavenController first;
      first = HavenController(
        api: firstApi,
        local: createRepository(),
        brokerAuthorize: (_, _, _) async => null,
        openNativeBrowser: (_) async {
          // Android can terminate Haven while the external browser is visible.
          expect(await firstApi.restoreNativeLogin(), isNotNull);
          first.dispose();
          return true;
        },
      );
      await first.signIn();
      final recoveredApi = HavenApi(
        base: origin,
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/native/poll') {
            final body = jsonDecode(request.body);
            expect(body['id'], 'request');
            expect(
              base64UrlEncode(
                sha256.convert(utf8.encode(body['verifier'])).bytes,
              ).replaceAll('=', ''),
              challenge,
            );
            return http.Response('{"token":"device-session"}', 200);
          }
          return connectedResponse(request);
        }),
      );
      final recovered = HavenController(
        api: recoveredApi,
        local: createRepository(),
        brokerAuthorize: (_, _, _) async =>
            throw StateError('Must resume existing login'),
        openNativeBrowser: (_) async =>
            throw StateError('Must not open another browser'),
      );
      addTearDown(recovered.dispose);
      await recovered.initialize();
      expect(recovered.ready, isTrue);
      expect(recovered.busy, isFalse);
      expect(await recoveredApi.restoreNativeLogin(), isNull);
      final restored = HavenApi(base: origin);
      addTearDown(restored.client.close);
      await restored.restore();
      expect(restored.token, 'device-session');
    },
  );

  test(
    'network loss and temporary server errors preserve the same login',
    () async {
      var polls = 0;
      final api = HavenApi(
        base: origin,
        client: MockClient((request) async {
          if (request.url.path != '/api/auth/native/poll') {
            return connectedResponse(request);
          }
          expect(jsonDecode(request.body), {
            'id': 'request',
            'verifier': 'v' * 43,
          });
          switch (++polls) {
            case 1:
              throw http.ClientException(
                'Network changed while browser was open',
              );
            case 2:
              return http.Response('{"error":"temporarily_unavailable"}', 503);
            case 3:
              return http.Response('{"status":"pending"}', 202);
            default:
              return http.Response('{"token":"device-session"}', 200);
          }
        }),
      );
      await api.saveNativeLogin(pending());
      final controller = HavenController(api: api, local: createRepository());
      addTearDown(controller.dispose);
      await controller.signIn();
      expect(polls, 4);
      expect(controller.ready, isTrue);
      expect(await api.restoreNativeLogin(), isNull);
    },
  );

  test(
    'logout discards pending approval and rejects a delayed poll result',
    () async {
      final polled = Completer<void>(), response = Completer<http.Response>();
      final api = HavenApi(
        base: origin,
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/logout') {
            return http.Response('{}', 200);
          }
          expect(request.url.path, '/api/auth/native/poll');
          polled.complete();
          return response.future;
        }),
      );
      await api.saveNativeLogin(pending());
      final controller = HavenController(api: api, local: createRepository());
      addTearDown(controller.dispose);
      final login = controller.signIn();
      await polled.future;
      await controller.logout();
      response.complete(http.Response('{"token":"late-session"}', 200));
      await login;
      expect(controller.ready, isFalse);
      expect(api.token, isNull);
      expect(await api.restoreNativeLogin(), isNull);
    },
  );

  test(
    'expired and malformed saved logins are removed and origin scoped',
    () async {
      final api = HavenApi(base: origin);
      addTearDown(api.client.close);
      await api.saveNativeLogin(pending(expires: 1));
      expect(await api.restoreNativeLogin(), isNull);
      await api.saveNativeLogin({
        'id': 'request',
        'verifier': 123,
        'expires': 9999999999999,
      });
      expect(await api.restoreNativeLogin(), isNull);
      await api.saveNativeLogin(pending());
      final other = HavenApi(base: 'https://other.example');
      addTearDown(other.client.close);
      expect(await other.restoreNativeLogin(), isNull);
      expect(await api.restoreNativeLogin(), isNotNull);
    },
  );

  test(
    'an expired server approval ends recovery and permits a fresh login',
    () async {
      final api = HavenApi(
        base: origin,
        client: MockClient(
          (request) async => http.Response('{"error":"unknown_login"}', 404),
        ),
      );
      await api.saveNativeLogin(pending());
      final controller = HavenController(api: api, local: createRepository());
      addTearDown(controller.dispose);
      await controller.signIn();
      expect(controller.busy, isFalse);
      expect(controller.ready, isFalse);
      expect(await api.restoreNativeLogin(), isNull);
    },
  );
}
