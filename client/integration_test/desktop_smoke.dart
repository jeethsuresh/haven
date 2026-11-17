import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:haven/main.dart';
import 'package:haven/controller.dart';
import 'package:haven/api.dart';
import 'package:haven/apple_photos.dart';
import 'package:haven/apple_photos_archive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

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
  if (Platform.isMacOS) {
    testWidgets('Photos archive restores metadata and rejects altered bytes', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final temp = await Directory.systemTemp.createTemp(
          'haven-archive-smoke-',
        );
        addTearDown(() => temp.delete(recursive: true));
        final package = Directory(p.join(temp.path, 'Fixture.photoslibrary'));
        final db = File(p.join(package.path, 'database', 'Photos.sqlite'));
        await db.parent.create(recursive: true);
        const id = 'ffffffff-ffff-ffff-ffff-ffffffffffff';
        final create = await Process.run('/usr/bin/sqlite3', [
          db.path,
          '''
          CREATE TABLE Z_METADATA(Z_UUID TEXT);
          INSERT INTO Z_METADATA VALUES ('$id');
          CREATE TABLE ZASSET(Z_PK INTEGER, ZUUID TEXT, ZFILENAME TEXT,
            ZDIRECTORY TEXT, ZKIND INTEGER);
          CREATE TABLE ZGENERICALBUM(Z_PK INTEGER, ZUUID TEXT, ZTITLE TEXT,
            ZKIND INTEGER);
          ''',
        ]);
        expect(create.exitCode, 0);
        expect(
          (await Process.run('/usr/bin/xattr', [
            '-w',
            'com.example.haven-smoke',
            'retained',
            package.path,
          ])).exitCode,
          0,
        );
        final result = await archiveApplePhotos(package.path, temp, (
          name,
        ) async {
          final file = File(p.join(temp.path, name));
          await file.parent.create(recursive: true);
          return file;
        });
        final destination = await Directory(
          p.join(temp.path, 'restore'),
        ).create();
        final archive = File(result.entry.ref);
        final restored = await restoreApplePhotosArchive(archive, destination);
        expect(
          (await ApplePhotosLibrary.read(restored, verifyIntegrity: true)).id,
          id,
        );
        final attr = await Process.run('/usr/bin/xattr', [
          '-p',
          'com.example.haven-smoke',
          restored,
        ]);
        expect(attr.exitCode, 0);
        expect((attr.stdout as String).trim(), 'retained');
        await archive.writeAsString('altered', mode: FileMode.append);
        await expectLater(
          restoreApplePhotosArchive(archive, destination),
          throwsStateError,
        );
        expect(await destination.list().length, 1);
      });
    });
  }
}
