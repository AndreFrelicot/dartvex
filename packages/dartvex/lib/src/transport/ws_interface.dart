/// Platform abstraction over the WebSocket implementation used by Dartvex.
abstract class WebSocketAdapter {
  /// Connects the adapter to [url].
  Future<void> connect(String url);

  /// Sends a raw text [message].
  void send(String message);

  /// Stream of raw text messages received from the socket.
  Stream<String> get messages;

  /// Stream that emits when the socket closes.
  Stream<void> get closeEvents;

  /// Closes the socket connection.
  Future<void> close();

  /// Whether the socket is currently connected.
  bool get isConnected;
}
