import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haven/native_broker.dart';
import 'package:haven/desktop_store_broker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('cool.gravitas.haven/auth');
  const origin = 'https://haven.gravitas.cool';
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
  test(
    'Android requests a one-use code without sending its verifier',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'broker');
            expect(call.arguments, {'challenge': 'c' * 43, 'state': 's' * 43});
            return {
              'status': 'authorized',
              'code': 'one-use',
              'sub': 'alice',
              'session_id': 'family',
            };
          });
      final response = await authorizeNativeBroker(origin, 'c' * 43, 's' * 43);
      expect(response?['code'], 'one-use');
      expect(
        await authorizeNativeBroker(
          'https://other.example',
          'c' * 43,
          's' * 43,
        ),
        isNull,
      );
    },
  );
  test(
    'missing Store uses browser; cancellation and outages stay explicit',
    () async {
      for (final status in ['browser', 'cancelled', 'unavailable']) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (_) async => {'status': status});
        final result = authorizeNativeBroker(origin, 'c' * 43, 's' * 43);
        if (status == 'cancelled') {
          await expectLater(result, throwsA(isA<StoreSignInCancelled>()));
        } else if (status == 'unavailable') {
          await expectLater(result, throwsStateError);
        } else {
          expect(await result, isNull);
        }
      }
    },
  );
}
