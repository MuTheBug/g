import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../local/secure_credential_store.dart';

/// One subscriber to a multiplexed WebSocket stream — created via
/// [BinanceWs.subscribe]. The returned [stream] only carries messages whose
/// envelope's `stream` field matches the subscriber's [name]; messages from
/// other multiplexed streams are silently filtered out for this consumer.
class _Subscription {
  _Subscription(this.name, this.controller);
  final String name;
  final StreamController<Map<String, dynamic>> controller;
}

/// Thin client over Binance Futures' combined-stream WebSocket endpoint
/// (`wss://fstream.binance.com/stream?streams=…`). Multiplexes any number of
/// subscriptions onto a single socket, auto-reconnects with exponential
/// backoff, and replays the active subscription set after every reconnect so
/// callers don't have to.
///
/// Public-stream URLs:
///   prod    : wss://fstream.binance.com
///   testnet : wss://stream.binancefuture.com
///
/// User-data streams use a different host (a per-listenKey URL) and are
/// handled by [connectUserDataStream] directly rather than going through
/// the multiplexer.
class BinanceWs {
  BinanceWs(this._creds);

  final SecureCredentialStore _creds;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socketSub;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  int _reconnectAttempts = 0;
  bool _disposed = false;

  /// All active subscribers keyed by stream name (e.g. `btcusdt@markPrice@1s`).
  final Map<String, _Subscription> _subs = {};

  String get _host =>
      (_creds.snapshot?.testnet ?? false)
          ? 'wss://stream.binancefuture.com'
          : 'wss://fstream.binance.com';

  /// Subscribe to a stream by its Binance name. Returns a broadcast [Stream]
  /// of decoded JSON payloads (the `data` field of the combined-stream
  /// envelope). Cancel the returned subscription via the returned [Stream]
  /// to unsubscribe — when the last subscriber for a stream cancels, we
  /// reconnect with the smaller set.
  Stream<Map<String, dynamic>> subscribe(String name) {
    var sub = _subs[name];
    if (sub == null) {
      sub = _Subscription(
        name,
        StreamController<Map<String, dynamic>>.broadcast(
          onCancel: () => _maybeRemove(name),
        ),
      );
      _subs[name] = sub;
      _ensureConnected();
    }
    return sub.controller.stream;
  }

  void _maybeRemove(String name) {
    final sub = _subs[name];
    if (sub == null) return;
    if (sub.controller.hasListener) return;
    _subs.remove(name);
    sub.controller.close();
    if (_subs.isEmpty) {
      _disconnect();
    } else {
      _reconnectSoon(immediate: true);
    }
  }

  void _ensureConnected() {
    if (_channel != null) return;
    _connect();
  }

  void _connect() {
    if (_disposed || _subs.isEmpty) return;
    _reconnectTimer?.cancel();
    final streams = _subs.keys.join('/');
    final url = Uri.parse('$_host/stream?streams=$streams');
    try {
      final ch = WebSocketChannel.connect(url);
      _channel = ch;
      _socketSub = ch.stream.listen(
        _onMessage,
        onError: (Object e, StackTrace _) {
          if (kDebugMode) debugPrint('BinanceWs error: $e');
          _scheduleReconnect();
        },
        onDone: _scheduleReconnect,
        cancelOnError: true,
      );
      _reconnectAttempts = 0;
      _startPing();
    } catch (e) {
      if (kDebugMode) debugPrint('BinanceWs connect failed: $e');
      _scheduleReconnect();
    }
  }

  void _onMessage(dynamic msg) {
    try {
      final decoded = jsonDecode(msg as String);
      if (decoded is! Map<String, dynamic>) return;
      // Combined-stream envelope: { "stream": "name", "data": { ... } }
      final stream = decoded['stream'];
      final data = decoded['data'];
      if (stream is String && data is Map<String, dynamic>) {
        final sub = _subs[stream];
        if (sub != null && !sub.controller.isClosed) {
          sub.controller.add(data);
        }
      }
    } catch (_) {/* ignore malformed frames */}
  }

  void _startPing() {
    _pingTimer?.cancel();
    // Binance's WS server expects ping/pong every 3 minutes. We send a
    // lightweight "ping" frame every 60s — the channel handles pong.
    _pingTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      try {
        _channel?.sink.add('{"id":"ping","method":"LIST_SUBSCRIPTIONS"}');
      } catch (_) {/* socket might be dying — _scheduleReconnect will fire */}
    });
  }

  void _scheduleReconnect() {
    _disconnect(scheduledByCaller: true);
    if (_disposed || _subs.isEmpty) return;
    _reconnectAttempts++;
    final delaySec = (1 << _reconnectAttempts.clamp(1, 6)).clamp(2, 60);
    _reconnectTimer = Timer(Duration(seconds: delaySec), _connect);
  }

  void _reconnectSoon({bool immediate = false}) {
    _reconnectTimer?.cancel();
    _disconnect(scheduledByCaller: true);
    _reconnectTimer = Timer(
      immediate ? Duration.zero : const Duration(milliseconds: 250),
      _connect,
    );
  }

  void _disconnect({bool scheduledByCaller = false}) {
    _pingTimer?.cancel();
    _pingTimer = null;
    _socketSub?.cancel();
    _socketSub = null;
    try {
      _channel?.sink.close();
    } catch (_) {}
    _channel = null;
    if (!scheduledByCaller) _reconnectTimer?.cancel();
  }

  /// Open a dedicated single-stream WebSocket for the user-data stream.
  /// The user-data WS lives at `<host>/ws/<listenKey>`, *not* through
  /// the multiplexer, because Binance issues a unique listenKey per session
  /// that must be POSTed to /fapi/v1/listenKey first and refreshed every
  /// 30 minutes via PUT.
  ///
  /// Returns a controller-style channel — the caller is responsible for
  /// closing it when done.
  Stream<Map<String, dynamic>> connectUserDataStream(String listenKey) {
    final url = Uri.parse('$_host/ws/$listenKey');
    final ch = WebSocketChannel.connect(url);
    final controller = StreamController<Map<String, dynamic>>.broadcast();
    final sub = ch.stream.listen(
      (msg) {
        try {
          final decoded = jsonDecode(msg as String);
          if (decoded is Map<String, dynamic>) controller.add(decoded);
        } catch (_) {}
      },
      onError: (Object e, StackTrace _) {
        if (kDebugMode) debugPrint('BinanceWs user-data error: $e');
        controller.addError(e);
      },
      onDone: controller.close,
      cancelOnError: false,
    );
    controller.onCancel = () async {
      await sub.cancel();
      try {
        await ch.sink.close();
      } catch (_) {}
    };
    return controller.stream;
  }

  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _disconnect();
    for (final s in _subs.values) {
      s.controller.close();
    }
    _subs.clear();
  }
}
