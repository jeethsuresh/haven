import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:haven/main.dart';
import 'package:haven/controller.dart';
import 'package:haven/api.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native bundle loads plugins, credentials, storage and the real UI',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final file = File('${support.path}/desktop-smoke.txt');
      await file.parent.create(recursive: true);
      await file.writeAsString('durable desktop data', flush: true);
      expect(await file.readAsString(), 'durable desktop data');
      await file.delete();
      const secrets = FlutterSecureStorage(
        mOptions: MacOsOptions(usesDataProtectionKeychain: false),
      );
      await secrets.write(
        key: 'desktop-smoke-only',
        value: 'encrypted desktop credential',
      );
      expect(
        await secrets.read(key: 'desktop-smoke-only'),
        'encrypted desktop credential',
      );
      await secrets.delete(key: 'desktop-smoke-only');
      final controller = HavenController(
        api: HavenApi(
          client: MockClient((request) async {
            return request.url.path == '/api/config'
                ? http.Response('{"dev":false,"stun_urls":[]}', 200)
                : http.Response('{"error":"sign_in"}', 401);
          }),
        ),
      );
      await tester.pumpWidget(HavenApp(controller: controller));
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(MaterialApp), findsOneWidget);
      expect(find.text('Continue with Gravitas'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
