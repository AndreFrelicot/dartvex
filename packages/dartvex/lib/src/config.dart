import 'logging.dart';
import 'transport/ws_interface.dart';

/// Factory for creating a platform-specific [WebSocketAdapter].
typedef WebSocketAdapterFactory = WebSocketAdapter Function(String clientId);

/// Configuration for a [ConvexClient] connection.
class ConvexClientConfig {
  /// Creates a client configuration.
  const ConvexClientConfig({
    this.clientId = 'dart-dartvex',
    this.apiVersion = '0.1.0',
    this.authTokenType = 'User',
    this.inactivityTimeout = const Duration(seconds: 30),
    this.reconnectBackoff = const <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 32),
    ],
    this.adapterFactory,
    this.logLevel = DartvexLogLevel.off,
    this.logger,
  });

  /// Client identifier sent when establishing the WebSocket connection.
  final String clientId;

  /// Convex sync API version path segment.
  final String apiVersion;

  /// Token type used when authenticating with Convex.
  final String authTokenType;

  /// Maximum time to wait for server messages before reconnecting.
  final Duration inactivityTimeout;

  /// Backoff schedule used for reconnect attempts.
  final List<Duration> reconnectBackoff;

  /// Optional override for the platform WebSocket adapter.
  final WebSocketAdapterFactory? adapterFactory;

  /// Minimum log level emitted by Dartvex internals.
  final DartvexLogLevel logLevel;

  /// Optional structured log sink.
  final DartvexLogger? logger;
}
