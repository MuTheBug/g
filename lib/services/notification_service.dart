import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> ensureInitialized() async {
    if (_initialized) return;
    try {
      const init = InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_apex_status'),
      );
      await _plugin.initialize(init);
      _initialized = true;
    } catch (e) {
      // Never let notification setup crash the app — the rest of the app works fine
      // without notifications.
      debugPrint('Notification init failed: $e');
    }
  }

  Future<bool> requestNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final status = await Permission.notification.request();
      return status.isGranted;
    } catch (_) {
      return false;
    }
  }

  Future<bool> areNotificationsAllowed() async {
    if (!Platform.isAndroid) return true;
    try {
      return await Permission.notification.isGranted;
    } catch (_) {
      return false;
    }
  }

  Future<void> showSignal({
    required String symbol,
    required String side,
    required int confidence,
    required double entry,
    required double sl,
    required double tp1,
    required int notifId,
  }) async {
    await ensureInitialized();
    try {
      const channel = AndroidNotificationDetails(
        'apex_signals',
        'Trading signals',
        channelDescription: 'High-confidence trade setups detected by the scanner.',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@drawable/ic_apex_status',
      );
      final body =
          'Entry ${entry.toStringAsFixed(4)} • SL ${sl.toStringAsFixed(4)} • TP1 ${tp1.toStringAsFixed(4)}';
      await _plugin.show(
        notifId,
        '$symbol $side • $confidence%',
        body,
        const NotificationDetails(android: channel),
      );
    } catch (e) {
      debugPrint('notify failed: $e');
    }
  }
}
