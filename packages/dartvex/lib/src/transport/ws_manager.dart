import 'dart:async';
import 'dart:convert';
import 'dart:math';

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

/// Returns whether the client has re-synced every query, auth update, and
/// request that predated the most recent reconnect.
typedef SyncedStateGetter = bool Function();

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

/// Initial reconnect backoff in milliseconds, keyed by server disconnect
/// reason prefix.
///
/// Mirrors the official Convex client's `serverDisconnectErrors` table so
/// overload conditions back off more conservatively than unknown failures.
const Map<String, int> _serverDisconnectBackoffMs = <String, int>{
  'InternalServerError': 1000,
  'SubscriptionsWorkerFullError': 3000,
  'TooManyConcurrentRequests': 3000,
  'CommitterFullError': 3000,
  'AwsTooManyRequestsException': 3000,
  'ExecuteFullError': 3000,
  'SystemTimeoutError': 3000,
  'ExpiredInQueue': 3000,
  'VectorIndexesUnavailable': 1000,
  'SearchIndexesUnavailable': 1000,
  'TableSummariesUnavailable': 1000,
  'VectorIndexTooLarge': 3000,
  'SearchIndexTooLarge': 3000,
  'TooManyWritesInTimePeriod': 3000,
};

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
    required this.hasSyncedPastLastReconnect,
    required this.reconnectBackoff,
    required this.inactivityTimeout,
    this.connectTimeout = const Duration(seconds: 10),
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 16),
    this.backoffJitter = 0.5,
    Random? random,
    this.onMessagesSent,
    this.onTransitionMetrics,
    this.logLevel = DartvexLogLevel.off,
    this.logger,
  }) : _random = random ?? Random();

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

  /// Reports whether the client has fully re-synced since the last reconnect.
  ///
  /// Consulted after each handled server message to decide whether the
  /// reconnect backoff may be reset. Mirrors the official client, which resets
  /// its retry counter based on this signal rather than on the message type, so
  /// a server that flaps before the client catches up keeps backing off.
  final SyncedStateGetter hasSyncedPastLastReconnect;

  /// Backoff schedule used for reconnects.
  final List<Duration> reconnectBackoff;

  /// Maximum idle duration before forcing a reconnect.
  final Duration inactivityTimeout;

  /// Maximum duration to wait for the socket handshake before abandoning the
  /// attempt and scheduling a reconnect.
  final Duration connectTimeout;

  /// Base delay for the exponential reconnect backoff (when [reconnectBackoff]
  /// is empty).
  final Duration initialBackoff;

  /// Upper bound for the exponential reconnect backoff delay.
  final Duration maxBackoff;

  /// Jitter fraction applied to each exponential backoff delay.
  final double backoffJitter;

  final Random _random;

  /// Optional callback that receives transition performance metrics.
  final TransitionMetricsCallback? onTransitionMetrics;

  /// Minimum log level emitted by the manager.
  final DartvexLogLevel logLevel;

  /// Structured log sink.
  final DartvexLogger? logger;

  _TransitionChunkBuffer? _chunkBuffer;
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
    _chunkBuffer = null;
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
    if (_connecting) {
      _pendingCloseReason = reason;
      return;
    }
    _pendingCloseReason = null;
    _closeHandled = true;
    _scheduleReconnect(immediate: true);
  }

  /// Cancels any pending reconnect backoff and reconnects immediately, but only
  /// while the manager is waiting to reconnect (disconnected with a scheduled
  /// retry).
  ///
  /// No-op when connected, mid-connect, or disposed. Used to react to a restored
  /// network connection without resetting the backoff progression.
  void reconnectImmediatelyIfWaiting() {
    if (_disposed || _connecting || adapter.isConnected) {
      return;
    }
    final timer = _reconnectTimer;
    if (timer == null || !timer.isActive) {
      return;
    }
    _log(
      DartvexLogLevel.info,
      'Reconnecting immediately after connectivity restore',
    );
    _scheduleReconnect(immediate: true);
  }

  /// Disposes timers, subscriptions, and the underlying socket.
  Future<void> dispose() async {
    _disposed = true;
    _log(DartvexLogLevel.debug, 'Disposing WebSocket manager');
    _reconnectTimer?.cancel();
    _inactivityTimer?.cancel();
    _chunkBuffer = null;
    await _messageSubscription?.cancel();
    await _closeSubscription?.cancel();
    await adapter.close();
  }

  void _attachListeners() {
    _messageSubscription ??= adapter.messages.listen((raw) {
      unawaited(_handleRawMessage(raw));
    });
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
      await adapter.connect(_buildWebSocketUrl()).timeout(connectTimeout);
      if (_disposed) {
        await adapter.close();
        return;
      }
      _connecting = false;
      _pendingCloseReason = null;
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
    } catch (error) {
      _connecting = false;
      final timedOut = error is TimeoutException;
      if (timedOut) {
        // Abort the half-open connect so it cannot open in the background after
        // we have already moved on to scheduling a reconnect.
        try {
          await adapter.close();
        } catch (_) {
          // Best effort; the socket is being discarded regardless.
        }
      }
      _log(
        DartvexLogLevel.error,
        'WebSocket connection failed',
        error: error,
      );
      await _handleClosed(
        WebSocketCloseEvent(
          errorMessage: timedOut
              ? 'ConnectTimeout after ${connectTimeout.inMilliseconds}ms'
              : error.toString(),
        ),
      );
    }
  }

  String _buildWebSocketUrl() {
    final uri = Uri.parse(deploymentUrl);
    final wsScheme = switch (uri.scheme) {
      'http' => 'ws',
      'ws' => 'ws',
      'wss' => 'wss',
      _ => 'wss',
    };
    return uri
        .replace(
          scheme: wsScheme,
          path: '/api/$apiVersion/sync',
          query: null,
          fragment: null,
        )
        .toString();
  }

  Future<void> _handleRawMessage(String raw) async {
    if (_disposed) {
      return;
    }
    try {
      _resetInactivityTimer();
      final messageLengthBytes = utf8.encode(raw).length;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw FormatException('Server message must be an object', raw);
      }
      var message = ServerMessage.fromJson(decoded);
      if (message is Ping) {
        return;
      }
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
      } else {
        if (_chunkBuffer != null) {
          _chunkBuffer = null;
          _log(
            DartvexLogLevel.warn,
            'Received non-chunk message while buffering TransitionChunks',
            data: <String, Object?>{'type': decoded['type']},
          );
        }
        if (message is Transition) {
          _reportTransitionMetrics(message, messageLengthBytes);
        }
      }
      final outgoing = await onMessage(message);
      // Reset the reconnect backoff only once the client has caught up on all
      // work that predated the last reconnect, rather than on every Transition
      // or response. This mirrors the official client and prevents a flapping
      // server from resetting the backoff before the connection proves itself.
      final syncedPastLastReconnect = hasSyncedPastLastReconnect();
      await sendMessages(outgoing);
      if (syncedPastLastReconnect) {
        _reconnectIndex = 0;
      }
    } catch (error, stackTrace) {
      _chunkBuffer = null;
      _lastCloseReason = 'InvalidServerMessage';
      _pendingCloseReason = _lastCloseReason;
      _log(
        DartvexLogLevel.error,
        'Failed to handle WebSocket message',
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
    }
  }

  _AssembledTransition? _appendTransitionChunk(TransitionChunk chunk) {
    final buffer = _chunkBuffer;
    if (chunk.totalParts <= 0 ||
        chunk.partNumber < 0 ||
        chunk.partNumber >= chunk.totalParts ||
        (buffer != null &&
            (buffer.totalParts != chunk.totalParts ||
                buffer.transitionId != chunk.transitionId))) {
      _chunkBuffer = null;
      throw FormatException('Invalid TransitionChunk', chunk.toJson());
    }

    final activeBuffer = buffer ??
        (_chunkBuffer = _TransitionChunkBuffer(
          totalParts: chunk.totalParts,
          transitionId: chunk.transitionId,
        ));

    if (chunk.partNumber != activeBuffer.parts.length) {
      final expectedPart = activeBuffer.parts.length;
      _chunkBuffer = null;
      throw FormatException(
        'TransitionChunk received out of order: expected part '
        '$expectedPart, got ${chunk.partNumber}',
        chunk.toJson(),
      );
    }

    activeBuffer.parts.add(chunk.chunk);
    if (activeBuffer.parts.length != activeBuffer.totalParts) {
      return null;
    }

    final assembled = activeBuffer.parts.join();
    _chunkBuffer = null;
    final decoded = jsonDecode(assembled);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
          'Assembled Transition must be an object', assembled);
    }
    final message = ServerMessage.fromJson(decoded);
    if (message is! Transition) {
      throw FormatException(
        'Expected Transition after assembling chunks, got ${decoded['type']}',
        decoded,
      );
    }
    return _AssembledTransition(
      transition: message,
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
    _chunkBuffer = null;
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
    final delay = _nextReconnectDelay(immediate: immediate);
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

  /// Computes the next reconnect delay and advances the retry counter.
  ///
  /// A non-empty [reconnectBackoff] schedule is used verbatim (no jitter);
  /// otherwise an exponential backoff with jitter is derived from
  /// [initialBackoff], [maxBackoff], [backoffJitter], and the disconnect reason
  /// classification.
  Duration _nextReconnectDelay({required bool immediate}) {
    if (immediate) {
      return Duration.zero;
    }
    if (reconnectBackoff.isNotEmpty) {
      final index = _reconnectIndex < reconnectBackoff.length
          ? _reconnectIndex
          : reconnectBackoff.length - 1;
      if (_reconnectIndex < reconnectBackoff.length - 1) {
        _reconnectIndex += 1;
      }
      return reconnectBackoff[index];
    }
    final baseMs = _classifiedInitialBackoffMs(_lastCloseReason).toDouble();
    final exponentialMs = baseMs * pow(2, _reconnectIndex).toDouble();
    final cappedMs = min(exponentialMs, maxBackoff.inMilliseconds.toDouble());
    _reconnectIndex += 1;
    final jitterSpan =
        cappedMs * backoffJitter * (_random.nextDouble() * 2 - 1);
    final delayMs = (cappedMs + jitterSpan).clamp(0.0, double.infinity);
    return Duration(milliseconds: delayMs.round());
  }

  int _classifiedInitialBackoffMs(String reason) {
    for (final entry in _serverDisconnectBackoffMs.entries) {
      if (reason.startsWith(entry.key)) {
        return entry.value;
      }
    }
    return initialBackoff.inMilliseconds;
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(inactivityTimeout, () async {
      if (_disposed) {
        return;
      }
      _lastCloseReason = 'ServerInactivity';
      _pendingCloseReason = _lastCloseReason;
      _log(DartvexLogLevel.warn, 'Closing WebSocket after inactivity timeout');
      try {
        await adapter.close();
      } catch (error, stackTrace) {
        _log(
          DartvexLogLevel.error,
          'Failed to close WebSocket after inactivity timeout',
          error: error,
          stackTrace: stackTrace,
        );
      }
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
  _TransitionChunkBuffer({
    required this.totalParts,
    required this.transitionId,
  });

  final int totalParts;
  final String transitionId;
  final List<String> parts = <String>[];
}

class _AssembledTransition {
  const _AssembledTransition({
    required this.transition,
    required this.messageLengthBytes,
  });

  final Transition transition;
  final int messageLengthBytes;
}
