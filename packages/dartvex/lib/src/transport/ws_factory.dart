import 'ws_interface.dart';
import 'ws_native.dart' if (dart.library.js_interop) 'ws_web.dart' as impl;

WebSocketAdapter createDefaultWebSocketAdapter(String clientId) {
  return impl.createWebSocketAdapter(clientId);
}
