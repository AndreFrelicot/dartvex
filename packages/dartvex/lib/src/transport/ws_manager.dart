import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import '../protocol/messages.dart';
import 'package:uuid/uuid.dart';
import 'ws_interface.dart';

typedef ConnectedMessageBuilder = FutureOr<List<ClientMessage>> Function();
typedef ServerMessageHandler = FutureOr<List<ClientMessage>> Function(
    ServerMessage message);
typedef DisconnectHandler = FutureOr<void> Function(String reason);
typedef ConnectionStateHandler = void Function(
    bool connected, bool reconnecting);
typedef TimestampGetter = String? Function();

/// Performance metrics for a received Transition message.
class TransitionMetrics {
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

class WebSocketManager {
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
    this.onTransitionMetrics,
  });

  final WebSocketAdapter adapter;
  final String deploymentUrl;
  final String apiVersion;
  final ConnectedMessageBuilder onConnected;
  final ServerMessageHandler onMessage;
  final DisconnectHandler onDisconnected;
  final ConnectionStateHandler onConnectionStateChanged;
  final TimestampGetter maxObservedTimestamp;
  final List<Duration> reconnectBackoff;
  final Duration inactivityTimeout;
  final TransitionMetricsCallback? onTransitionMetrics;

  final Map<String, _TransitionChunkBuffer> _chunkBuffers =
      <String, _TransitionChunkBuffer>{};
  final Uuid _uuid = const Uuid();

  StreamSubscription<String>? _messageSubscription;
  StreamSubscription<void>? _closeSubscription;
  Timer? _reconnectTimer;
  Timer? _inactivityTimer;

  bool _disposed = false;
  bool _connecting = false;
  int _connectionCount = 0;
  int _reconnectIndex = 0;
  String _lastCloseReason = 'InitialConnect';

  bool get isConnected => adapter.isConnected;

  Future<void> start() async {
    _attachListeners();
    await _connect();
  }

  Future<void> sendMessages(List<ClientMessage> messages) async {
    if (!adapter.isConnected) {
      return;
    }
    for (final message in messages) {
      adapter.send(jsonEncode(message.toJson()));
    }
  }

  Future<void> reconnectNow(String reason) async {
    _lastCloseReason = reason;
    if (adapter.isConnected) {
      await adapter.close();
      return;
    }
    _scheduleReconnect(immediate: true);
  }

  Future<void> dispose() async {
    _disposed = true;
    _reconnectTimer?.cancel();
    _inactivityTimer?.cancel();
    await _messageSubscription?.cancel();
    await _closeSubscription?.cancel();
    await adapter.close();
  }

  void _attachListeners() {
    _messageSubscription ??= adapter.messages.listen(_handleRawMessage);
    _closeSubscription ??= adapter.closeEvents.listen((_) {
      unawaited(_handleClosed(_lastCloseReason));
    });
  }

  Future<void> _connect() async {
    if (_disposed || _connecting) {
      return;
    }
    _connecting = true;
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
      onConnectionStateChanged(true, false);
      adapter.send(
        jsonEncode(
          Connect(
            sessionId: _uuid.v4(),
            connectionCount: _connectionCount,
            lastCloseReason: _lastCloseReason,
            maxObservedTimestamp: maxObservedTimestamp(),
            clientTs: DateTime.now().millisecondsSinceEpoch,
          ).toJson(),
        ),
      );
      final reconnectMessages = await onConnected();
      await sendMessages(reconnectMessages);
      _reconnectIndex = 0;
    } catch (error) {
      _connecting = false;
      await _handleClosed(error.toString());
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
      developer.log(
        'Warning: received ${(messageLengthBytes / 1e6).toStringAsFixed(1)}MB transition - '
        'consider reducing query result sizes for mobile connections',
        name: 'dartvex.transition',
        level: 900,
      );
    } else if (transitTimeMs > 20000) {
      developer.log(
        'Warning: transition took ${transitTimeMs.round()}ms to arrive - '
        'check network conditions or query result sizes',
        name: 'dartvex.transition',
        level: 900,
      );
    }
  }

  Future<void> _handleClosed(String reason) async {
    if (_disposed) {
      return;
    }
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
    _reconnectTimer = Timer(delay, () {
      unawaited(_connect());
    });
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(inactivityTimeout, () async {
      _lastCloseReason = 'ServerInactivity';
      await adapter.close();
    });
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
