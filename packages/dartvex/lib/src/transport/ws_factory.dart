import 'ws_interface.dart';
import 'ws_native.dart' if (dart.library.js_interop) 'ws_web.dart' as impl;

/// Creates the default platform-specific WebSocket adapter.
WebSocketAdapter createDefaultWebSocketAdapter(String clientId) {
  return impl.createWebSocketAdapter(clientId);
}
