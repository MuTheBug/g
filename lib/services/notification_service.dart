import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  /// Symbol payload of the most recent tapped notification — populated by
  /// either the cold-start launch details or the in-process tap callback.
  /// Cleared once the router consumes it via [consumePendingSymbol].
  final ValueNotifier<String?> pendingSymbol = ValueNotifier<String?>(null);

  String? consumePendingSymbol() {
    final v = pendingSymbol.value;
    pendingSymbol.value = null;
    return v;
  }

  Future<void> ensureInitialized() async {
    if (_initialized) return;
    try {
      const init = InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_apex_status'),
      );
      await _plugin.initialize(
        init,
        onDidReceiveNotificationResponse: _onTap,
      );
      _initialized = true;

      // If the user launched the app by tapping a notification (cold start),
      // capture the payload so the router can navigate to the trade screen
      // for that symbol once the home destination renders.
      try {
        final launch = await _plugin.getNotificationAppLaunchDetails();
        if (launch?.didNotificationLaunchApp ?? false) {
          final payload = launch?.notificationResponse?.payload;
          if (payload != null && payload.isNotEmpty) {
            pendingSymbol.value = payload;
          }
        }
      } catch (_) {/* never fatal */}
    } catch (e) {
      debugPrint('Notification init failed: $e');
    }
  }

  void _onTap(NotificationResponse response) {
    final payload = response.payload;
    if (payload != null && payload.isNotEmpty) {
      pendingSymbol.value = payload;
    }
  }

  /// Use the plugin's native Android 13+ permission request rather than going
  /// through `permission_handler`, which has known crashes on Flutter Android
  /// setups where the activity isn't fully ready when the system dialog
  /// returns. The plugin handles the FragmentActivity context correctly.
  Future<bool> requestNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    await ensureInitialized();
    try {
      final android =
          _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return true; // Plugin unavailable — treat as ok.
      final granted = await android.requestNotificationsPermission();
      return granted ?? true; // null on older Androids = no permission needed.
    } catch (e) {
      debugPrint('requestNotificationPermission failed: $e');
      return false;
    }
  }

  Future<bool> areNotificationsAllowed() async {
    if (!Platform.isAndroid) return true;
    await ensureInitialized();
    try {
      final android =
          _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return true;
      final enabled = await android.areNotificationsEnabled();
      return enabled ?? true;
    } catch (e) {
      debugPrint('areNotificationsAllowed failed: $e');
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
        // Payload is the symbol — the app pulls it via consumePendingSymbol()
        // and the router pushes /trade/{symbol} or /signal/{symbol}.
        payload: symbol,
      );
    } catch (e) {
      debugPrint('notify failed: $e');
    }
  }
}
