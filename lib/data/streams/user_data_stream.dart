import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/binance_api.dart';
import '../api/binance_ws.dart';

/// One event from the Binance Futures user-data stream. We only model the
/// types the app reacts to today; everything else is exposed via [raw].
@immutable
class UserDataEvent {
  const UserDataEvent({required this.type, required this.raw, this.eventTime});
  final String type;
  final int? eventTime;
  final Map<String, dynamic> raw;
}

/// Manages the user-data stream lifecycle:
///   - POST /fapi/v1/listenKey at start
///   - PUT  /fapi/v1/listenKey every 30 minutes (TTL is 60 min)
///   - Reconnect on listenKeyExpired
///   - DELETE /fapi/v1/listenKey on dispose
///
/// Yields a broadcast stream of [UserDataEvent]s. Errors trigger automatic
/// reconnect with a fresh listenKey; the stream stays open for the consumer.
class UserDataStream {
  UserDataStream(this._api, this._ws);

  final BinanceApi _api;
  final BinanceWs _ws;

  StreamController<UserDataEvent>? _controller;
  StreamSubscription<dynamic>? _innerSub;
  Timer? _keepalive;
  bool _disposed = false;
  String? _listenKey;
  int _attempt = 0;

  Stream<UserDataEvent> get stream {
    final existing = _controller;
    if (existing != null && !existing.isClosed) return existing.stream;
    final c = StreamController<UserDataEvent>.broadcast(
      onListen: _start,
      onCancel: () {
        if (_controller?.hasListener == false) _stop();
      },
    );
    _controller = c;
    return c.stream;
  }

  Future<void> _start() async {
    if (_disposed) return;
    try {
      final key = await _api.startUserDataStream();
      if (key.isEmpty) {
        _scheduleReconnect();
        return;
      }
      _listenKey = key;
      _attempt = 0;
      final inner = _ws.connectUserDataStream(key);
      _innerSub = inner.listen(
        (msg) {
          final type = msg['e'] as String? ?? '';
          final ts = (msg['E'] as num?)?.toInt();
          if (type == 'listenKeyExpired') {
            _scheduleReconnect();
            return;
          }
          _controller?.add(UserDataEvent(type: type, raw: msg, eventTime: ts));
        },
        onError: (Object e, StackTrace _) {
          if (kDebugMode) debugPrint('user-data error: $e');
          _scheduleReconnect();
        },
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
      _keepalive?.cancel();
      _keepalive = Timer.periodic(const Duration(minutes: 30), (_) async {
        try {
          await _api.keepaliveUserDataStream();
        } catch (e) {
          if (kDebugMode) debugPrint('listenKey keepalive failed: $e');
          _scheduleReconnect();
        }
      });
    } catch (e) {
      if (kDebugMode) debugPrint('user-data start failed: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _innerSub?.cancel();
    _innerSub = null;
    _keepalive?.cancel();
    _keepalive = null;
    _attempt++;
    final secs = (1 << _attempt.clamp(1, 6)).clamp(2, 60);
    Timer(Duration(seconds: secs), _start);
  }

  void _stop() {
    _innerSub?.cancel();
    _innerSub = null;
    _keepalive?.cancel();
    _keepalive = null;
    _controller?.close();
    _controller = null;
    if (_listenKey != null) {
      // Best-effort — if the close fails, Binance reaps it after 60 min.
      _api.closeUserDataStream().catchError((_) {});
      _listenKey = null;
    }
  }

  void dispose() {
    _disposed = true;
    _stop();
  }
}
