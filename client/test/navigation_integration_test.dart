import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/controller.dart';
import 'package:haven/main.dart';
import 'package:haven/model.dart';
import 'gravitas_navigation_test.dart' as navigation;

class NavigationController extends HavenController {
  NavigationController() {
    loading = false;
    ready = true;
    account = 'one';
  }
  @override
  Future<void> initialize() async {}
  @override
  Future<Uint8List?> thumbnail(MediaAsset asset) async => null;

  void switchAccount() {
    account = 'two';
    changed();
  }
}

void main() {
  setUpAll(() async {
    final config =
        jsonDecode(File('.dart_tool/package_config.json').readAsStringSync())
            as Map;
    final packages = config['packages'] as List;
    final root = Uri.parse(
      '${packages.firstWhere((p) => p['name'] == 'flutter')['rootUri']}/',
    );
    final bytes = await File.fromUri(
      root.resolve(
        '../../bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
      ),
    ).readAsBytes();
    final font = FontLoader('sans-serif')
      ..addFont(Future.value(ByteData.sublistView(bytes)));
    await font.load();
  });
  testWidgets('photo details show only verified current storage copies', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = NavigationController()
      ..assets = [
        MediaAsset(
          {
            'id': 'photo',
            'kind': 'media',
            'mime': 'image/jpeg',
            'path': 'holiday.jpg',
            'revisions': [
              {'id': 'old', 'size': 100, 'sha256': 'old-hash'},
              {'id': 'current', 'size': 100, 'sha256': 'current-hash'},
            ],
          },
          1,
          [
            {'revision_id': 'old', 'device_id': 'old-drive'},
            {'revision_id': 'current', 'device_id': 'backups'},
          ],
        ),
      ]
      ..devices = [
        {
          'id': 'backups',
          'name': 'Studio backups',
          'roles': ['sink'],
        },
        {
          'id': 'old-drive',
          'name': 'Old drive',
          'roles': ['sink'],
        },
      ];
    await tester.pumpWidget(HavenApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.text('holiday.jpg'));
    await tester.pumpAndSettle();
    expect(find.text('1 verified copy'), findsOneWidget);
    expect(find.text('Studio backups'), findsOneWidget);
    expect(find.text('Old drive'), findsNothing);
    expect(find.text('current-hash'), findsNothing);

    controller.switchAccount();
    await tester.pumpAndSettle();
    expect(find.text('This item is no longer available.'), findsOneWidget);
    expect(find.text('Studio backups'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  for (final width in [390.0, 1200.0]) {
    testWidgets(
      'library destinations restore and history cannot cross accounts at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final controller = NavigationController();
        await tester.pumpWidget(HavenApp(controller: controller));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 'summer');
        await tester.pumpAndSettle();
        if (width < 900) {
          await tester.tap(find.byTooltip('Open navigation menu'));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.widgetWithText(ListTile, 'Photos'));
        await tester.pumpAndSettle();
        expect(find.text('Media library'), findsNothing);
        await navigation.back(tester);
        expect(find.text('Media library'), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          'summer',
        );
        await navigation.forward(tester);
        expect(find.text('Media library'), findsNothing);
        if (width < 900) {
          await tester.tap(find.byTooltip('Open navigation menu'));
          await tester.pumpAndSettle();
          await navigation.back(tester);
          expect(find.text('Media library'), findsNothing);
        }
        await navigation.back(tester);
        controller.switchAccount();
        await tester.pumpAndSettle();
        await navigation.forward(tester);
        expect(find.text('Media library'), findsOneWidget);
        expect(
          tester
              .widget<TextField>(find.byType(TextField).first)
              .controller!
              .text,
          isEmpty,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
