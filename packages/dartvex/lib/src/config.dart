import 'transport/ws_interface.dart';

typedef WebSocketAdapterFactory = WebSocketAdapter Function(String clientId);

class ConvexClientConfig {
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
  });

  final String clientId;
  final String apiVersion;
  final String authTokenType;
  final Duration inactivityTimeout;
  final List<Duration> reconnectBackoff;
  final WebSocketAdapterFactory? adapterFactory;
}
