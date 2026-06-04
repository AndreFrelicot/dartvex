import 'logging.dart';
import 'transport/connectivity.dart';
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
    this.refreshTokenLeewaySeconds = 2,
    this.inactivityTimeout = const Duration(seconds: 30),
    this.connectTimeout = const Duration(seconds: 10),
    this.queryTimeout,
    this.mutationTimeout,
    this.actionTimeout,
    this.reconnectBackoff = const <Duration>[],
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 16),
    this.backoffJitter = 0.5,
    this.connectImmediately = true,
    this.adapterFactory,
    this.connectivitySignal,
    this.logLevel = DartvexLogLevel.off,
    this.logger,
  });

  /// Client identifier sent when establishing the WebSocket connection.
  final String clientId;

  /// Convex sync API version path segment.
  final String apiVersion;

  /// Token type used when authenticating with Convex.
  final String authTokenType;

  /// How many seconds before a token's expiration the client proactively
  /// refreshes it.
  ///
  /// The refresh is scheduled from the token's own lifetime (`exp - iat`) minus
  /// this leeway rather than from the device wall clock, so scheduling stays
  /// correct even when the device clock is skewed. If the leeway is larger than
  /// the token's lifetime the client refreshes immediately. Defaults to `2`.
  final int refreshTokenLeewaySeconds;

  /// Maximum time to wait for server messages before reconnecting.
  final Duration inactivityTimeout;

  /// Maximum time to wait for the WebSocket handshake to complete before
  /// abandoning the attempt and scheduling a reconnect.
  ///
  /// Without this bound, a dead connection (for example after a network drop)
  /// can hang on the platform's TCP connect timeout for tens of seconds,
  /// blocking every reconnect attempt until the operating system gives up.
  final Duration connectTimeout;

  /// Optional maximum wait for [ConvexClient.query] before cancelling the
  /// temporary subscription and completing with a `TimeoutException`.
  final Duration? queryTimeout;

  /// Optional maximum wait for [ConvexClient.mutate] before completing the
  /// returned future with a `TimeoutException`.
  ///
  /// A timed-out mutation may still complete on the backend if it was already
  /// sent. Use idempotent mutation design for operations with external side
  /// effects.
  final Duration? mutationTimeout;

  /// Optional maximum wait for [ConvexClient.action] before completing the
  /// returned future with a `TimeoutException`.
  ///
  /// A timed-out action may still complete on the backend if it was already
  /// sent.
  final Duration? actionTimeout;

  /// Optional fixed backoff schedule used for reconnect attempts.
  ///
  /// When empty (the default), reconnects use an exponential backoff derived
  /// from [initialBackoff], [maxBackoff], and [backoffJitter], with the initial
  /// delay classified by the server's disconnect reason. Provide an explicit,
  /// non-negative schedule to override that behavior with fixed delays.
  final List<Duration> reconnectBackoff;

  /// Base delay for the exponential reconnect backoff.
  ///
  /// Used when [reconnectBackoff] is empty. Server overload disconnect reasons
  /// can raise this initial value before exponential growth is applied.
  final Duration initialBackoff;

  /// Upper bound for the exponential reconnect backoff delay.
  final Duration maxBackoff;

  /// Jitter fraction applied to each exponential backoff delay, in `[0, 1]`.
  ///
  /// A value of `0.5` spreads delays across `±50%` of the computed value to
  /// avoid reconnect stampedes (thundering herd).
  final double backoffJitter;

  /// Whether the WebSocket connection starts when the client is constructed.
  ///
  /// Set to `false` to defer opening the socket until the first backend
  /// operation, auth update, or explicit reconnect request.
  final bool connectImmediately;

  /// Optional override for the platform WebSocket adapter.
  final WebSocketAdapterFactory? adapterFactory;

  /// Optional signal used to reconnect immediately when the device regains
  /// network connectivity, cancelling any in-progress reconnect backoff.
  ///
  /// Leave `null` (the default) to rely solely on backoff. Flutter apps can
  /// supply a `connectivity_plus`-backed implementation from `dartvex_flutter`.
  final ConnectivitySignal? connectivitySignal;

  /// Minimum log level emitted by Dartvex internals.
  final DartvexLogLevel logLevel;

  /// Optional structured log sink.
  final DartvexLogger? logger;
}
