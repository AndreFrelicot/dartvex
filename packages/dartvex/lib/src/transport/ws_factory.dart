import '../config.dart' show WebSocketAdapterFactory;
import 'ws_interface.dart';
import 'ws_native.dart' if (dart.library.js_interop) 'ws_web.dart' as impl;

/// Process-wide override for the default WebSocket adapter factory.
///
/// When non-null, [createDefaultWebSocketAdapter] delegates to this factory
/// instead of the built-in platform adapter. Used by platform integrations
/// (for example `dartvex_flutter` on iOS/macOS, which installs an
/// NSURLSession-backed adapter at startup) to swap the default transport for
/// every client in the process without touching per-client configuration.
///
/// An explicit `ConvexClientConfig.adapterFactory` always takes precedence
/// over this override: the override only applies where the default adapter
/// would have been used.
WebSocketAdapterFactory? defaultWebSocketAdapterOverride;

/// Creates the default platform-specific WebSocket adapter.
///
/// Honors [defaultWebSocketAdapterOverride] when set; otherwise returns the
/// built-in adapter for the current platform (`dart:io` sockets on native,
/// browser WebSocket on web).
WebSocketAdapter createDefaultWebSocketAdapter(String clientId) {
  final override = defaultWebSocketAdapterOverride;
  if (override != null) {
    return override(clientId);
  }
  return impl.createWebSocketAdapter(clientId);
}
