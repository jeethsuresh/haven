import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/controller.dart';
import 'package:haven/main.dart';
import 'gravitas_navigation_test.dart' as navigation;

class NavigationController extends HavenController {
  NavigationController() {
    loading = false;
    ready = true;
    account = 'one';
  }
  @override
  Future<void> initialize() async {}
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
  testWidgets(
    'library destinations restore and history cannot cross accounts',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = NavigationController();
      await tester.pumpWidget(HavenApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Photos'));
      await tester.pumpAndSettle();
      expect(find.text('Media library'), findsNothing);
      await navigation.back(tester);
      expect(find.text('Media library'), findsOneWidget);
      await navigation.forward(tester);
      expect(find.text('Media library'), findsNothing);
      await navigation.back(tester);
      controller.switchAccount();
      await tester.pumpAndSettle();
      await navigation.forward(tester);
      expect(find.text('Media library'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
