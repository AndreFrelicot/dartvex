abstract class WebSocketAdapter {
  Future<void> connect(String url);
  void send(String message);
  Stream<String> get messages;
  Stream<void> get closeEvents;
  Future<void> close();
  bool get isConnected;
}
