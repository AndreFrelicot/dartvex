import 'logging.dart';
import 'transport/connectivity.dart';
import 'transport/ws_interface.dart';

/// The Dartvex package version, kept in sync with `pubspec.yaml`.
///
/// Sent as part of the default [ConvexClientConfig.clientId]
/// (`dartvex-<version>`) so Convex can tell Dartvex releases apart. A test
/// asserts it matches the pubspec version, so bump both together.
const String dartvexVersion = '0.2.0';

/// The Convex sync protocol version Dartvex reports by default.
///
/// Used as the default [ConvexClientConfig.apiVersion], which becomes the
/// `/api/<version>/sync` path segment of the WebSocket URL — the only client
/// version signal browsers (and Dart web) can send, since they cannot set
/// headers. It is pinned to the official Convex JavaScript client release whose
/// sync protocol (`protocol.ts`, `web_socket_manager.ts`) and value encoding
/// Dartvex implements, and is bumped deliberately as part of a release after
/// diffing those sources against the targeted Convex release.
const String convexSyncApiVersion = '1.49.0';

/// Factory for creating a platform-specific [WebSocketAdapter].
typedef WebSocketAdapterFactory = WebSocketAdapter Function(String clientId);

/// Configuration for a [ConvexClient] connection.
class ConvexClientConfig {
  /// Creates a client configuration.
  const ConvexClientConfig({
    this.clientId = 'dartvex-$dartvexVersion',
    this.apiVersion = convexSyncApiVersion,
    this.authTokenType = 'User',
    this.refreshTokenLeewaySeconds = 10,
    this.inactivityTimeout = const Duration(seconds: 60),
    this.connectTimeout = const Duration(seconds: 10),
    this.queryTimeout,
    this.mutationTimeout,
    this.actionTimeout,
    this.reconnectBackoff = const <Duration>[],
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 16),
    this.backoffJitter = 0.5,
    this.connectImmediately = true,
    this.expectAuth = false,
    this.adapterFactory,
    this.connectivitySignal,
    this.logLevel = DartvexLogLevel.off,
    this.logger,
  });

  /// Client identifier sent when establishing the WebSocket connection.
  ///
  /// Native adapters send it as the `Convex-Client` header. The default,
  /// `dartvex-<version>` (see [dartvexVersion]), follows the
  /// `<client>-<semver>` format the Convex backend parses, so deployments can
  /// tell Dartvex releases apart.
  final String clientId;

  /// Convex sync API version path segment.
  ///
  /// Defaults to [convexSyncApiVersion]: the official Convex JavaScript client
  /// release whose sync protocol Dartvex implements. Convex uses this path
  /// segment for client compatibility checks, especially for browser
  /// WebSockets where custom headers cannot be sent. Override it only to pin a
  /// different protocol level.
  final String apiVersion;

  /// Token type used when authenticating with Convex.
  final String authTokenType;

  /// How many seconds before a token's expiration the client proactively
  /// refreshes it.
  ///
  /// The refresh is scheduled from the token's own lifetime (`exp - iat`) minus
  /// this leeway rather than from the device wall clock, so scheduling stays
  /// correct even when the device clock is skewed. If the leeway is larger than
  /// the token's lifetime the client refreshes immediately. Defaults to `10`,
  /// matching the official Convex client.
  final int refreshTokenLeewaySeconds;

  /// Maximum time to wait for server messages before reconnecting.
  ///
  /// Defaults to 60 seconds, matching the official Convex client. Convex sends
  /// regular pings, but a large downstream message can monopolize the
  /// connection; the longer threshold avoids false reconnects mid-message.
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

  /// Whether the client should hold every query, mutation, and action until
  /// auth has been decided.
  ///
  /// When `true`, the client starts paused: the socket may open, but nothing is
  /// sent until the first `setAuth`, `setAuthWithRefresh`, or `clearAuth` call
  /// releases the pause. Queries subscribed during app start (for example
  /// while `ConvexClientWithAuth.loginFromCache` waits on the auth provider)
  /// then run authenticated from the start instead of running unauthenticated
  /// first and again once the token lands. A client created with
  /// `expectAuth: true` that never receives an auth call stays paused — call
  /// `clearAuth()` when the user is known to be signed out. Defaults to
  /// `false`. Mirrors the official client's `expectAuth` option.
  final bool expectAuth;

  /// Optional override for the platform WebSocket adapter.
  ///
  /// Advanced/testing seam: supply a factory returning a custom
  /// [WebSocketAdapter] to route the sync transport through your own socket
  /// implementation (for example to inject instrumentation or a mock in tests).
  /// Leave `null` (the default) to use the platform adapter selected by
  /// conditional import.
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
