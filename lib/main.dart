import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'data/local/database.dart';
import 'data/local/secure_credential_store.dart';
import 'services/background_service.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock to portrait — trading UI is dense and not friendly to landscape.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Surface unhandled framework + isolate errors to logcat instead of letting
  // them silently bring down the activity. Anything else in this app is wrapped
  // in try/catch at the call site, so this is purely a safety net.
  FlutterError.onError = (details) {
    FlutterError.dumpErrorToConsole(details);
    debugPrint('FRAMEWORK ERROR: ${details.exceptionAsString()}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('UNCAUGHT: $error\n$stack');
    return true; // signal handled — don't crash the engine
  };

  // Open the local SQLite database before any repository read. The one-time
  // SharedPreferences → SQLite import happens inside open() so older builds
  // upgrade transparently.
  await DatabaseService.instance.ensureInitialized();

  // Eagerly load credentials so the router knows the start destination
  // synchronously on first frame.
  await SecureCredentialStore.instance.load();
  // Initialize plugins — both wrap their own try/catch so a failure here is logged
  // not fatal.
  await NotificationService.instance.ensureInitialized();
  await BackgroundService.instance.ensureInitialized();

  runApp(const ProviderScope(child: ApexApp()));
}
