import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:haven/api.dart';
import 'package:haven/controller.dart';
import 'package:haven/local_stub.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native broker channel and encrypted browser recovery work', (
    tester,
  ) async {
    // The fresh CI emulator has no Store. Exercise the actual Android adapter,
    // not a mocked method channel, and require a safe browser fallback.
    final result = await const MethodChannel('cool.gravitas.haven/auth')
        .invokeMapMethod<String, dynamic>('broker', {
          'challenge': 'c' * 43,
          'state': 's' * 43,
        });
    expect(result?['status'], 'browser');
    var browsers = 0;
    final api = HavenApi(
      base: 'https://haven.gravitas.cool',
      client: MockClient((request) async {
        expect(request.url.path, '/api/auth/native/start');
        return http.Response(
          '{"id":"android-smoke","approval_url":"https://haven.gravitas.cool/auth/gravitas/start"}',
          200,
        );
      }),
    );
    await api.saveNativeLogin(null);
    final controller = HavenController(
      api: api,
      local: createRepository(),
      openNativeBrowser: (uri) async {
        browsers++;
        expect((await api.restoreNativeLogin())?['id'], 'android-smoke');
        return false;
      },
    );
    addTearDown(controller.dispose);
    await controller.signIn();
    expect(browsers, 1);
    expect(controller.busy, false);
    expect(controller.ready, false);
    expect(await api.restoreNativeLogin(), isNull);
    expect(controller.message, contains('Could not open sign-in browser'));
  });
}
