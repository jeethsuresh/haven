import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'desktop_broker.dart' as desktop;
import 'desktop_store_broker.dart';

Future<Map<String, dynamic>?> authorizeNativeBroker(
  String origin,
  String challenge,
  String state,
) async {
  if (kIsWeb) return null;
  if (defaultTargetPlatform != TargetPlatform.android) {
    return desktop.authorize(origin, challenge, state);
  }
  if (origin != 'https://haven.gravitas.cool') return null;
  try {
    final result = await const MethodChannel('cool.gravitas.haven/auth')
        .invokeMapMethod<String, dynamic>('broker', {
          'challenge': challenge,
          'state': state,
        });
    switch (result?['status']) {
      case 'cancelled':
        throw StoreSignInCancelled();
      case 'unavailable':
        throw StateError(
          'Private Store is temporarily unavailable. Try again or use browser sign-in.',
        );
      case 'authorized':
        return result;
      default:
        return null;
    }
  } on MissingPluginException {
    return null;
  } on PlatformException {
    throw StateError(
      'Private Store is temporarily unavailable. Try again or use browser sign-in.',
    );
  }
}
