import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Implements the "Termux-style" minimize behaviour:
///
///  - [start] pins a persistent low-priority notification in the status bar
///    so Android keeps our process alive and the user can tap it to bring
///    the app back to the foreground.
///  - [minimize] sends the activity to the background (`MoveTaskToBack`)
///    without killing it, leaving the persistent notification visible.
///
/// We deliberately avoid `flutter_foreground_task` — its API churns between
/// versions and has been a crash source for users.
class ApexForegroundService {
  ApexForegroundService._();
  static final ApexForegroundService instance = ApexForegroundService._();

  static const _channelId = 'apex_running';
  static const _channelName = 'Apex Trader running';
  static const _notifId = 4242;
  static const _hostChannel = MethodChannel('apex_trader/host');

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _channelEnsured = false;
  bool _running = false;

  bool get isRunning => _running;

  Future<void> _ensureChannel() async {
    if (_channelEnsured || !Platform.isAndroid) return;
    try {
      const init = InitializationSettings(
        android: AndroidInitializationSettings('@drawable/ic_apex_status'),
      );
      await _plugin.initialize(init);
      final android =
          _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(
        const AndroidNotificationChannel(
          _channelId,
          _channelName,
          description:
              'Keeps the scanner alive in the background. Tap to re-open the app.',
          importance: Importance.low,
          showBadge: false,
        ),
      );
      _channelEnsured = true;
    } catch (e) {
      debugPrint('Foreground channel init failed: $e');
    }
  }

  /// Shows the persistent "Apex Trader running" notification. Returns false
  /// if notification permission is missing or anything throws — the caller
  /// can surface that to the UI.
  Future<bool> start() async {
    if (!Platform.isAndroid) return false;
    await _ensureChannel();
    try {
      const details = NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          channelDescription:
              'Keeps the scanner alive in the background. Tap to re-open the app.',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          autoCancel: false,
          showWhen: false,
          onlyAlertOnce: true,
          icon: '@drawable/ic_apex_status',
          category: AndroidNotificationCategory.service,
        ),
      );
      await _plugin.show(
        _notifId,
        'Apex Trader',
        'Scanner running. Tap to open.',
        details,
      );
      _running = true;
      return true;
    } catch (e) {
      debugPrint('Foreground start failed: $e');
      return false;
    }
  }

  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _plugin.cancel(_notifId);
    } catch (e) {
      debugPrint('Foreground stop failed: $e');
    }
    _running = false;
  }

  /// Sends the Flutter activity to the background. Unlike `SystemNavigator.pop`
  /// which destroys the activity, this keeps the Dart isolate alive so the
  /// scan state survives the "minimize" gesture.
  Future<void> minimize() async {
    if (!Platform.isAndroid) return;
    try {
      await _hostChannel.invokeMethod<void>('moveTaskToBack');
    } catch (e) {
      debugPrint('minimize failed: $e');
    }
  }
}
