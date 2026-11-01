import 'dart:io';
import 'desktop_store_broker.dart';

Future<Map<String, dynamic>?> authorize(
  String origin,
  String challenge,
  String state,
) => (Platform.isLinux || Platform.isMacOS || Platform.isWindows)
    ? authorizeDesktopStore(
        appOrigin: origin,
        challenge: challenge,
        state: state,
      )
    : Future.value(null);
