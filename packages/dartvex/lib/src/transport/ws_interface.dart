/// Metadata reported when a WebSocket connection closes.
class WebSocketCloseEvent {
  /// Creates a close event.
  const WebSocketCloseEvent({
    this.code,
    this.reason,
    this.wasClean,
    this.errorMessage,
  });

  /// WebSocket close code, when exposed by the platform.
  final int? code;

  /// WebSocket close reason, when exposed by the platform.
  final String? reason;

  /// Whether the platform reported a clean close.
  final bool? wasClean;

  /// Transport error message associated with the close, when available.
  final String? errorMessage;

  /// Human-readable reason suitable for diagnostics and reconnect metadata.
  String get diagnosticReason {
    final explicitReason = reason;
    if (explicitReason != null && explicitReason.isNotEmpty) {
      return explicitReason;
    }
    final explicitError = errorMessage;
    if (explicitError != null && explicitError.isNotEmpty) {
      return explicitError;
    }
    final explicitCode = code;
    if (explicitCode != null) {
      return 'WebSocket closed with code $explicitCode';
    }
    return 'WebSocket closed';
  }
}

/// Platform abstraction over the WebSocket implementation used by Dartvex.
abstract class WebSocketAdapter {
  /// Connects the adapter to [url].
  Future<void> connect(String url);

  /// Sends a raw text [message].
  void send(String message);

  /// Stream of raw text messages received from the socket.
  Stream<String> get messages;

  /// Stream that emits when the socket closes.
  Stream<WebSocketCloseEvent> get closeEvents;

  /// Closes the socket connection.
  Future<void> close();

  /// Whether the socket is currently connected.
  bool get isConnected;
}
