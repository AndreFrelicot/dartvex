import 'dart:async';
import 'dart:convert';

import '../logging.dart';
import '../protocol/messages.dart';
import 'package:uuid/uuid.dart';
import 'ws_interface.dart';

/// Builds the initial messages to send once the socket connects.
typedef ConnectedMessageBuilder = FutureOr<List<ClientMessage>> Function();

/// Handles a decoded server message and returns any outgoing responses.
typedef ServerMessageHandler = FutureOr<List<ClientMessage>> Function(
    ServerMessage message);

/// Called when the socket disconnects.
typedef DisconnectHandler = FutureOr<void> Function(String reason);

/// Called with client messages that were handed to the socket adapter.
typedef SentMessagesHandler = void Function(List<ClientMessage> messages);

/// Reports low-level socket connection state.
typedef ConnectionStateHandler = void Function(
    bool connected, bool reconnecting);

/// Returns the maximum timestamp observed by the client.
typedef TimestampGetter = String? Function();

/// Performance metrics for a received Transition message.
class TransitionMetrics {
  /// Creates transition performance metrics.
  const TransitionMetrics({
    required this.transitTimeMs,
    required this.messageSizeBytes,
    required this.bytesPerSecond,
  });

  /// Estimated network transit time in milliseconds.
  final double transitTimeMs;

  /// Raw WebSocket message size in bytes.
  final int messageSizeBytes;

  /// Estimated throughput in bytes/second.
  final double bytesPerSecond;

  @override
  String toString() => 'TransitionMetrics(transit: ${transitTimeMs.round()}ms, '
      'size: ${(messageSizeBytes / 1e6).toStringAsFixed(1)}MB, '
      'throughput: ${(bytesPerSecond / 1e6).toStringAsFixed(1)}MB/s)';
}

/// Callback type for transition performance monitoring.
typedef TransitionMetricsCallback = void Function(TransitionMetrics metrics);

/// Manages the WebSocket lifecycle, reconnects, and message dispatch.
class WebSocketManager {
  /// Creates a WebSocket manager.
  WebSocketManager({
    required this.adapter,
    required this.deploymentUrl,
    required this.apiVersion,
    required this.onConnected,
    required this.onMessage,
    required this.onDisconnected,
    required this.onConnectionStateChanged,
    required this.maxObservedTimestamp,
    required this.reconnectBackoff,
    required this.inactivityTimeout,
    this.onMessagesSent,
    this.onTransitionMetrics,
    this.logLevel = DartvexLogLevel.off,
    this.logger,
  });

  /// WebSocket adapter used for network I/O.
  final WebSocketAdapter adapter;

  /// Base Convex deployment URL.
  final String deploymentUrl;

  /// Sync API version path segment.
  final String apiVersion;

  /// Callback invoked after a successful connection.
  final ConnectedMessageBuilder onConnected;

  /// Callback invoked for each decoded server message.
  final ServerMessageHandler onMessage;

  /// Callback invoked when the socket disconnects.
  final DisconnectHandler onDisconnected;

  /// Callback invoked after messages are handed to the socket adapter.
  final SentMessagesHandler? onMessagesSent;

  /// Callback used to publish connection state changes.
  final ConnectionStateHandler onConnectionStateChanged;

  /// Getter for the highest timestamp observed so far.
  final TimestampGetter maxObservedTimestamp;

  /// Backoff schedule used for reconnects.
  final List<Duration> reconnectBackoff;

  /// Maximum idle duration before forcing a reconnect.
  final Duration inactivityTimeout;

  /// Optional callback that receives transition performance metrics.
  final TransitionMetricsCallback? onTransitionMetrics;

  /// Minimum log level emitted by the manager.
  final DartvexLogLevel logLevel;

  /// Structured log sink.
  final DartvexLogger? logger;

  final Map<String, _TransitionChunkBuffer> _chunkBuffers =
      <String, _TransitionChunkBuffer>{};
  final String _sessionId = const Uuid().v4();

  StreamSubscription<String>? _messageSubscription;
  StreamSubscription<WebSocketCloseEvent>? _closeSubscription;
  Timer? _reconnectTimer;
  Timer? _inactivityTimer;

  bool _disposed = false;
  bool _connecting = false;
  bool _closeHandled = false;
  int _connectionCount = 0;
  int _reconnectIndex = 0;
  String _lastCloseReason = 'InitialConnect';
  String? _pendingCloseReason;

  /// Whether the socket adapter is currently connected.
  bool get isConnected => adapter.isConnected;

  /// Starts the WebSocket lifecycle.
  Future<void> start() async {
    _attachListeners();
    _log(DartvexLogLevel.debug, 'Starting WebSocket manager');
    await _connect();
  }

  /// Sends a batch of client protocol [messages] if connected.
  ///
  /// Returns the prefix of [messages] that was handed to the adapter.
  Future<List<ClientMessage>> sendMessages(List<ClientMessage> messages) async {
    if (!adapter.isConnected) {
      return const <ClientMessage>[];
    }
    final sentMessages = <ClientMessage>[];
    try {
      for (final message in messages) {
        if (!adapter.isConnected) {
          break;
        }
        adapter.send(jsonEncode(message.toJson()));
        sentMessages.add(message);
      }
    } catch (error, stackTrace) {
      _notifyMessagesSent(sentMessages);
      _lastCloseReason = 'FailedToSendMessage';
      _pendingCloseReason = _lastCloseReason;
      _log(
        DartvexLogLevel.error,
        'Failed to send WebSocket message',
        error: error,
        stackTrace: stackTrace,
      );
      if (adapter.isConnected) {
        await adapter.close();
      } else {
        _pendingCloseReason = null;
        _closeHandled = true;
        _scheduleReconnect(immediate: true);
      }
      return sentMessages;
    }
    _notifyMessagesSent(sentMessages);
    return sentMessages;
  }

  void _notifyMessagesSent(List<ClientMessage> messages) {
    if (messages.isEmpty) {
      return;
    }
    onMessagesSent?.call(List<ClientMessage>.unmodifiable(messages));
  }

  /// Forces a reconnect using [reason] as the last close reason.
  Future<void> reconnectNow(String reason) async {
    _lastCloseReason = reason;
    _log(
      DartvexLogLevel.info,
      'Reconnect requested',
      data: <String, Object?>{'reason': reason},
    );
    if (adapter.isConnected) {
      _pendingCloseReason = reason;
      await adapter.close();
      return;
    }
    _pendingCloseReason = null;
    _closeHandled = true;
    _scheduleReconnect(immediate: true);
  }

  /// Disposes timers, subscriptions, and the underlying socket.
  Future<void> dispose() async {
    _disposed = true;
    _log(DartvexLogLevel.debug, 'Disposing WebSocket manager');
    _reconnectTimer?.cancel();
    _inactivityTimer?.cancel();
    await _messageSubscription?.cancel();
    await _closeSubscription?.cancel();
    await adapter.close();
  }

  void _attachListeners() {
    _messageSubscription ??= adapter.messages.listen(_handleRawMessage);
    _closeSubscription ??= adapter.closeEvents.listen((event) {
      unawaited(_handleClosed(event));
    });
  }

  Future<void> _connect() async {
    if (_disposed || _connecting) {
      return;
    }
    _connecting = true;
    _closeHandled = false;
    _log(
      DartvexLogLevel.info,
      'Connecting WebSocket',
      data: <String, Object?>{'deploymentUrl': deploymentUrl},
    );
    onConnectionStateChanged(false, true);
    try {
      await adapter.connect(_buildWebSocketUrl());
      if (_disposed) {
        await adapter.close();
        return;
      }
      _connecting = false;
      _reconnectTimer?.cancel();
      _resetInactivityTimer();
      _log(DartvexLogLevel.info, 'WebSocket connected');
      adapter.send(
        jsonEncode(
          Connect(
            sessionId: _sessionId,
            connectionCount: _connectionCount,
            lastCloseReason: _lastCloseReason,
            maxObservedTimestamp: maxObservedTimestamp(),
            clientTs: DateTime.now().millisecondsSinceEpoch,
          ).toJson(),
        ),
      );
      final reconnectMessages = await onConnected();
      await sendMessages(reconnectMessages);
      if (!adapter.isConnected) {
        return;
      }
      onConnectionStateChanged(true, false);
      _reconnectIndex = 0;
    } catch (error) {
      _connecting = false;
      _log(
        DartvexLogLevel.error,
        'WebSocket connection failed',
        error: error,
      );
      await _handleClosed(WebSocketCloseEvent(errorMessage: error.toString()));
    }
  }

  String _buildWebSocketUrl() {
    final uri = Uri.parse(deploymentUrl);
    final wsScheme = switch (uri.scheme) {
      'http' => 'ws',
      _ => 'wss',
    };
    return uri
        .replace(scheme: wsScheme, path: '/api/$apiVersion/sync')
        .toString();
  }

  Future<void> _handleRawMessage(String raw) async {
    _resetInactivityTimer();
    final messageLengthBytes = utf8.encode(raw).length;
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('Server message must be an object', raw);
    }
    var message = ServerMessage.fromJson(decoded);
    if (message is TransitionChunk) {
      final assembledTransition = _appendTransitionChunk(message);
      if (assembledTransition == null) {
        return;
      }
      _reportTransitionMetrics(
        assembledTransition.transition,
        assembledTransition.messageLengthBytes,
      );
      message = assembledTransition.transition;
    } else if (message is Transition) {
      _reportTransitionMetrics(message, messageLengthBytes);
    }
    final outgoing = await onMessage(message);
    await sendMessages(outgoing);
  }

  _AssembledTransition? _appendTransitionChunk(TransitionChunk chunk) {
    final buffer = _chunkBuffers.putIfAbsent(
      chunk.transitionId,
      () => _TransitionChunkBuffer(totalParts: chunk.totalParts),
    );
    buffer.parts[chunk.partNumber] = utf8.decode(base64Decode(chunk.chunk));
    if (buffer.parts.length != buffer.totalParts) {
      return null;
    }
    final assembled = List<String>.generate(
      buffer.totalParts,
      (index) => buffer.parts[index + 1] ?? '',
    ).join();
    _chunkBuffers.remove(chunk.transitionId);
    final decoded = jsonDecode(assembled);
    return _AssembledTransition(
      transition: Transition.fromJson((decoded as Map).cast<String, dynamic>()),
      messageLengthBytes: utf8.encode(assembled).length,
    );
  }

  void _reportTransitionMetrics(Transition transition, int messageLengthBytes) {
    if (transition.clientClockSkew == null || transition.serverTs == null) {
      return;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch.toDouble();
    final transitTimeMs =
        nowMs - transition.clientClockSkew! - transition.serverTs! / 1e6;
    if (transitTimeMs <= 0) {
      return;
    }

    final metrics = TransitionMetrics(
      transitTimeMs: transitTimeMs,
      messageSizeBytes: messageLengthBytes,
      bytesPerSecond: messageLengthBytes / (transitTimeMs / 1000),
    );
    onTransitionMetrics?.call(metrics);

    if (messageLengthBytes > 20000000) {
      _log(
        DartvexLogLevel.warn,
        'Received oversized transition',
        data: <String, Object?>{
          'messageSizeBytes': messageLengthBytes,
          'messageSizeMb': double.parse(
            (messageLengthBytes / 1e6).toStringAsFixed(1),
          ),
        },
      );
    } else if (transitTimeMs > 20000) {
      _log(
        DartvexLogLevel.warn,
        'Transition arrived slowly',
        data: <String, Object?>{
          'transitTimeMs': transitTimeMs.round(),
          'messageSizeBytes': messageLengthBytes,
        },
      );
    }
  }

  Future<void> _handleClosed(WebSocketCloseEvent event) async {
    if (_disposed || _closeHandled) {
      return;
    }
    _closeHandled = true;
    final reason = _pendingCloseReason ?? event.diagnosticReason;
    _pendingCloseReason = null;
    _log(
      DartvexLogLevel.info,
      'WebSocket closed',
      data: <String, Object?>{
        'reason': reason,
        if (event.code != null) 'code': event.code,
        if (event.reason != null && event.reason!.isNotEmpty)
          'closeReason': event.reason,
        if (event.wasClean != null) 'wasClean': event.wasClean,
        if (event.errorMessage != null && event.errorMessage!.isNotEmpty)
          'errorMessage': event.errorMessage,
      },
    );
    _inactivityTimer?.cancel();
    _connecting = false;
    onConnectionStateChanged(false, false);
    await onDisconnected(reason);
    _lastCloseReason = reason;
    _connectionCount += 1;
    _scheduleReconnect();
  }

  void _scheduleReconnect({bool immediate = false}) {
    if (_disposed) {
      return;
    }
    _reconnectTimer?.cancel();
    final delay = immediate
        ? Duration.zero
        : reconnectBackoff[_reconnectIndex < reconnectBackoff.length
            ? _reconnectIndex
            : reconnectBackoff.length - 1];
    if (_reconnectIndex < reconnectBackoff.length - 1) {
      _reconnectIndex += 1;
    }
    _log(
      DartvexLogLevel.info,
      'Reconnect scheduled',
      data: <String, Object?>{
        'delayMs': delay.inMilliseconds,
        'connectionCount': _connectionCount,
        'reason': _lastCloseReason,
      },
    );
    _reconnectTimer = Timer(delay, () {
      unawaited(_connect());
    });
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(inactivityTimeout, () async {
      _lastCloseReason = 'ServerInactivity';
      _pendingCloseReason = _lastCloseReason;
      _log(DartvexLogLevel.warn, 'Closing WebSocket after inactivity timeout');
      await adapter.close();
    });
  }

  void _log(
    DartvexLogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) {
    emitDartvexLog(
      configuredLevel: logLevel,
      logger: logger,
      eventLevel: level,
      message: message,
      tag: 'transport.ws',
      error: error,
      stackTrace: stackTrace,
      data: data,
    );
  }
}

class _TransitionChunkBuffer {
  _TransitionChunkBuffer({required this.totalParts});

  final int totalParts;
  final Map<int, String> parts = <int, String>{};
}

class _AssembledTransition {
  const _AssembledTransition({
    required this.transition,
    required this.messageLengthBytes,
  });

  final Transition transition;
  final int messageLengthBytes;
}
