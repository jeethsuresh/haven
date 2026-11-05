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
  testWidgets(
    'library destinations restore and history cannot cross accounts',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
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
