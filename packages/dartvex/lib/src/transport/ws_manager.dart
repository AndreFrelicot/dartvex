import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:meta/meta.dart';

import '../logging.dart';
import '../protocol/messages.dart';
import 'package:uuid/uuid.dart';
import 'monotonic_clock.dart';
import 'ws_interface.dart';

/// Builds the initial messages to send once the socket connects.
typedef ConnectedMessageBuilder = FutureOr<List<ClientMessage>> Function();

/// Handles a decoded server message.
///
/// Any value the handler returns is ignored: a handler that needs to send
/// messages must route them through the client's re-queueing flush, because
/// the transport drops sends while the socket is paused or disconnected and
/// this return path has no way to re-queue them.
typedef ServerMessageHandler = FutureOr<void> Function(ServerMessage message);

/// Called when the socket disconnects.
typedef DisconnectHandler = FutureOr<void> Function(String reason);

/// Called with client messages that were handed to the socket adapter.
typedef SentMessagesHandler = void Function(List<ClientMessage> messages);

/// Reports low-level socket connection state.
typedef ConnectionStateHandler = void Function(
    bool connected, bool reconnecting);

/// Returns the maximum timestamp observed by the client.
typedef TimestampGetter = String? Function();

/// Returns whether the client has re-synced every query, auth update, and
/// request that predated the most recent reconnect.
typedef SyncedStateGetter = bool Function();

/// Receives a human-readable description of an abnormal server disconnect.
///
/// See [WebSocketManager.onServerDisconnectError].
typedef ServerDisconnectErrorHandler = void Function(String message);

/// WebSocket close codes that are expected during normal operation and are
/// therefore not reported through [ServerDisconnectErrorHandler]. Mirrors the
/// official client: normal closure, going away (common when a mobile app is
/// backgrounded), no status, and Convex's retryable "not found" (transient
/// during a deployment push).
const Set<int> _expectedCloseCodes = <int>{1000, 1001, 1005, 4040};

/// Performance metrics for a received Transition message.
class TransitionMetrics {
  /// Creates transition performance metrics.
  const TransitionMetrics({
    required this.transitTimeMs,
    required this.messageSizeBytes,
    required this.bytesPerSecond,
  });

  /// Estimated network transit time in milliseconds.
  final double transitTimeMs;

  /// Raw WebSocket message size in bytes.
  final int messageSizeBytes;

  /// Estimated throughput in bytes/second.
  final double bytesPerSecond;

  @override
  String toString() => 'TransitionMetrics(transit: ${transitTimeMs.round()}ms, '
      'size: ${(messageSizeBytes / 1e6).toStringAsFixed(1)}MB, '
      'throughput: ${(bytesPerSecond / 1e6).toStringAsFixed(1)}MB/s)';
}

/// Callback type for transition performance monitoring.
typedef TransitionMetricsCallback = void Function(TransitionMetrics metrics);

/// Initial reconnect backoff in milliseconds, keyed by server disconnect
/// reason prefix.
///
/// Mirrors the official Convex client's `serverDisconnectErrors` table so
/// overload conditions back off more conservatively than unknown failures.
const Map<String, int> _serverDisconnectBackoffMs = <String, int>{
  'InternalServerError': 1000,
  'SubscriptionsWorkerFullError': 3000,
  'TooManyConcurrentRequests': 3000,
  'CommitterFullError': 3000,
  'AwsTooManyRequestsException': 3000,
  'ExecuteFullError': 3000,
  'SystemTimeoutError': 3000,
  'ExpiredInQueue': 3000,
  'VectorIndexesUnavailable': 1000,
  'SearchIndexesUnavailable': 1000,
  'TableSummariesUnavailable': 1000,
  'VectorIndexTooLarge': 3000,
  'SearchIndexTooLarge': 3000,
  'TooManyWritesInTimePeriod': 3000,
};

/// Initial reconnect backoff (ms) for a *client-initiated* reconnect — one the
/// client triggers itself: a forced [WebSocketManager.reconnectNow], a detected
/// protocol error (`InvalidServerMessage`/`FailedToSendMessage`), or a
/// server-inactivity timeout.
///
/// Mirrors the official client's `nextBackoff("client")`, which uses a 100ms
/// base — a faster first retry than the 1s used for an unexpected,
/// unclassified server/network close, since a client-initiated reconnect is not
/// evidence of a struggling server. The usual exponential growth and jitter
/// still apply on top, so a persistently failing reconnect still backs off
/// rather than hot-looping.
const int _clientReconnectInitialBackoffMs = 100;

/// Pause sub-state of an open or connecting socket.
///
/// Mirrors the official client's `Socket.paused` field: [no] flushes normally,
/// [yes] buffers sends until [WebSocketManager.resume], and [uninitialized]
/// marks a socket that opened while paused so its handshake is deferred to
/// resume rather than run on connect.
enum _SocketPauseState { no, yes, uninitialized }

/// Manages the WebSocket lifecycle, reconnects, and message dispatch.
class WebSocketManager {
  /// Creates a WebSocket manager.
  WebSocketManager({
    required this.adapter,
    required this.deploymentUrl,
    required this.apiVersion,
    required this.onConnected,
    required this.onMessage,
    required this.onDisconnected,
    required this.onConnectionStateChanged,
    required this.maxObservedTimestamp,
    required this.hasSyncedPastLastReconnect,
    required this.reconnectBackoff,
    required this.inactivityTimeout,
    this.onResume,
    this.connectTimeout = const Duration(seconds: 10),
    this.initialBackoff = const Duration(seconds: 1),
    this.maxBackoff = const Duration(seconds: 16),
    this.backoffJitter = 0.5,
    Random? random,
    MonotonicClock? clock,
    this.onMessagesSent,
    this.onTransitionMetrics,
    this.onStatusChanged,
    this.onServerDisconnectError,
    this.logLevel = DartvexLogLevel.off,
    this.logger,
  })  : _random = random ?? Random(),
        _clock = clock ?? MonotonicClock();

  /// WebSocket adapter used for network I/O.
  final WebSocketAdapter adapter;

  /// Base Convex deployment URL.
  final String deploymentUrl;

  /// Sync API version path segment.
  final String apiVersion;

  /// Callback invoked after a successful connection.
  final ConnectedMessageBuilder onConnected;

  /// Callback invoked when the socket resumes after a [pause], returning the
  /// messages buffered while paused so they can be flushed in order.
  final ConnectedMessageBuilder? onResume;

  /// Callback invoked for each decoded server message.
  final ServerMessageHandler onMessage;

  /// Callback invoked when the socket disconnects.
  final DisconnectHandler onDisconnected;

  /// Callback invoked after messages are handed to the socket adapter.
  final SentMessagesHandler? onMessagesSent;

  /// Callback used to publish connection state changes.
  final ConnectionStateHandler onConnectionStateChanged;

  /// Getter for the highest timestamp observed so far.
  final TimestampGetter maxObservedTimestamp;

  /// Reports whether the client has fully re-synced since the last reconnect.
  ///
  /// Consulted after each handled server message to decide whether the
  /// reconnect backoff may be reset. Mirrors the official client, which resets
  /// its retry counter based on this signal rather than on the message type, so
  /// a server that flaps before the client catches up keeps backing off.
  final SyncedStateGetter hasSyncedPastLastReconnect;

  /// Backoff schedule used for reconnects.
  final List<Duration> reconnectBackoff;

  /// Maximum idle duration before forcing a reconnect.
  final Duration inactivityTimeout;

  /// Maximum duration to wait for the socket handshake before abandoning the
  /// attempt and scheduling a reconnect.
  final Duration connectTimeout;

  /// Base delay for the exponential reconnect backoff (when [reconnectBackoff]
  /// is empty).
  final Duration initialBackoff;

  /// Upper bound for the exponential reconnect backoff delay.
  final Duration maxBackoff;

  /// Jitter fraction applied to each exponential backoff delay.
  final double backoffJitter;

  final Random _random;

  /// Monotonic clock backing `Connect.clientTs` and transition transit metrics,
  /// so they remain meaningful even if the device wall clock is corrected.
  final MonotonicClock _clock;

  /// Optional callback that receives transition performance metrics.
  ///
  /// User code: an exception thrown here is logged and otherwise ignored, so
  /// it can never drop the Transition or force a reconnect.
  final TransitionMetricsCallback? onTransitionMetrics;

  /// Optional callback invoked when a transport metric that is not tied to a
  /// connection-state transition changes (currently [connectionRetries]), so
  /// the owner can republish its connection status snapshot.
  final void Function()? onStatusChanged;

  /// Optional, experimental hook that receives a description of an abnormal
  /// server disconnect, for telemetry.
  ///
  /// Invoked for a server/network close that carries a close reason and whose
  /// close code is not one of the codes expected during normal operation
  /// (1000, 1001, 1005, 4040). Never invoked for client-initiated closes.
  /// Mirrors the official client's unstable `onServerDisconnectError` option;
  /// which reasons are reported may change. An exception thrown by the
  /// callback is logged and otherwise ignored.
  final ServerDisconnectErrorHandler? onServerDisconnectError;

  /// Minimum log level emitted by the manager.
  final DartvexLogLevel logLevel;

  /// Structured log sink.
  final DartvexLogger? logger;

  _TransitionChunkBuffer? _chunkBuffer;
  final String _sessionId = const Uuid().v4();

  StreamSubscription<String>? _messageSubscription;
  StreamSubscription<WebSocketCloseEvent>? _closeSubscription;
  Timer? _reconnectTimer;
  Timer? _inactivityTimer;

  /// Serializes message handling so a handler that awaits (an auth refresh or a
  /// reconnect) cannot interleave with the next incoming message. Each message
  /// is chained after the previous one completes; errors are isolated so the
  /// chain never stalls.
  ///
  /// Close events are routed through the same chain, so frames the socket
  /// delivered before it closed are always handled before the disconnect
  /// bookkeeping runs. Without this, a response and a close arriving in the
  /// same read could be processed close-first, failing an action whose
  /// response was already on hand.
  Future<void> _messageQueue = Future<void>.value();

  bool _disposed = false;
  bool _connecting = false;
  bool _closeHandled = false;
  bool _stopped = false;

  /// Monotonic id of the latest connect attempt. [stop] advances it so a
  /// continuation of an in-flight [_connect] that resumes after a
  /// stop()/restart() cycle can detect it was superseded and bail out instead
  /// of running its handshake against the newer attempt's socket (which would
  /// write a second `Connect` frame onto it — a protocol violation).
  int _connectAttempt = 0;

  /// Identity of the connection incoming frames belong to. Advanced whenever
  /// a connection is torn down or replaced (a new connect attempt, [stop], a
  /// handled close or synthetic disconnect), so frames queued from the old
  /// connection are discarded rather than applied to the next session.
  int _socketEpoch = 0;
  _SocketPauseState _pauseState = _SocketPauseState.no;
  int _connectionCount = 0;

  /// Index into the backoff progression. In fixed-schedule mode it is clamped
  /// to the schedule's last entry; [_connectionRetries] is the unbounded
  /// public counter.
  int _reconnectIndex = 0;

  /// Reconnect attempts scheduled since the last successful re-sync; backs
  /// [connectionRetries]. Reset at the same sites as [_reconnectIndex].
  int _connectionRetries = 0;
  bool _hasEverConnected = false;

  /// Close reason reported in the next `Connect` frame.
  ///
  /// Mirrors the official client: starts as `InitialConnect`, is cleared once
  /// a `Connect` frame has been sent, is set unconditionally by a
  /// client-initiated close, and is only filled in by a server/network close
  /// (or a failed reconnect attempt) when no reason is recorded yet — so the
  /// first disconnect's reason survives failed retries.
  String? _lastCloseReason = 'InitialConnect';
  String? _pendingCloseReason;

  /// When the pending reconnect timer was scheduled (monotonic ms) and its
  /// delay, so a connectivity-restore shortcut can report the time it saved.
  int? _reconnectScheduledAtMs;
  int _reconnectScheduledDelayMs = 0;

  /// Backoff time skipped by the last connectivity-restore reconnect, reported
  /// to the server as a `NetworkRecoveryReconnect` event once that reconnect's
  /// handshake completes.
  int? _pendingNetworkRecoveryTimeSavedMs;

  /// Whether the socket adapter is currently connected.
  ///
  /// Only means the adapter is open: while [isPaused] the socket may still be
  /// waiting for its deferred handshake, and [sendMessages] sends nothing.
  bool get isConnected => adapter.isConnected;

  /// Whether the socket is [pause]d for auth, so [sendMessages] sends nothing
  /// until [resume] flushes the buffered state.
  bool get isPaused => _pauseState != _SocketPauseState.no;

  /// Whether the socket has ever reached the connected (ready) state.
  ///
  /// Once `true` it stays `true`, distinguishing "never connected yet" from
  /// "disconnected after a successful connection". Mirrors the official
  /// client's `hasEverConnected`.
  bool get hasEverConnected => _hasEverConnected;

  /// The number of times the socket has reconnected, as carried by [Connect].
  ///
  /// Incremented after each successful socket open; a high value signals
  /// repeated connection churn.
  int get connectionCount => _connectionCount;

  /// The number of reconnect attempts since the last successful re-sync.
  ///
  /// Counts connect attempts since the last successful re-sync and is reset to
  /// zero once the client has caught up (see [hasSyncedPastLastReconnect]).
  /// Keeps counting past the end of a fixed [reconnectBackoff] schedule.
  /// Mirrors the official client's `connectionRetries`.
  int get connectionRetries => _connectionRetries;

  /// The current reading of the monotonic clock that stamps `Connect.clientTs`.
  ///
  /// Combined with a Transition's `clientClockSkew` (computed by the server
  /// from that same `clientTs`), this yields the client's estimate of the
  /// server's current time.
  int get clientNowMillis => _clock.nowMillis;

  /// Starts the WebSocket lifecycle.
  Future<void> start() async {
    _attachListeners();
    _log(DartvexLogLevel.debug, 'Starting WebSocket manager');
    await _connect();
  }

  /// Sends a batch of client protocol [messages] if connected.
  ///
  /// Returns the prefix of [messages] that was handed to the adapter.
  Future<List<ClientMessage>> sendMessages(List<ClientMessage> messages) async {
    if (!adapter.isConnected || _pauseState != _SocketPauseState.no) {
      return const <ClientMessage>[];
    }
    final sentMessages = <ClientMessage>[];
    try {
      for (final message in messages) {
        if (!adapter.isConnected) {
          break;
        }
        adapter.send(jsonEncode(message.toJson()));
        sentMessages.add(message);
      }
    } catch (error, stackTrace) {
      _notifyMessagesSent(sentMessages);
      _lastCloseReason = 'FailedToSendMessage';
      _pendingCloseReason = _lastCloseReason;
      _log(
        DartvexLogLevel.error,
        'Failed to send WebSocket message',
        error: error,
        stackTrace: stackTrace,
      );
      await _closeOrSyntheticDisconnect(_lastCloseReason!,
          clientInitiated: true);
      return sentMessages;
    }
    _notifyMessagesSent(sentMessages);
    return sentMessages;
  }

  void _notifyMessagesSent(List<ClientMessage> messages) {
    if (messages.isEmpty) {
      return;
    }
    onMessagesSent?.call(List<ClientMessage>.unmodifiable(messages));
  }

  /// Records that the socket reached the connected (ready) state and publishes
  /// the connected transition. Sets [hasEverConnected] on the first success.
  void _markConnected() {
    _hasEverConnected = true;
    _connectionCount += 1;
    onConnectionStateChanged(true, false);
  }

  /// Forces a reconnect using [reason] as the last close reason.
  ///
  /// Uses the 100ms client-initiated backoff base. While the manager is
  /// already waiting out a reconnect backoff, the pending wait is replaced by
  /// a fresh client-base delay instead of being left to run its course.
  /// No-op while stopped for a reauth (the reauth's restart owns the
  /// connection) or after dispose.
  Future<void> reconnectNow(String reason) async {
    _log(
      DartvexLogLevel.info,
      'Reconnect requested',
      data: <String, Object?>{'reason': reason},
    );
    if (_disposed || _stopped) {
      return;
    }
    if (adapter.isConnected) {
      _chunkBuffer = null;
      _lastCloseReason = reason;
      _pendingCloseReason = reason;
      await _closeOrSyntheticDisconnect(reason, clientInitiated: true);
      return;
    }
    if (_connecting) {
      _lastCloseReason = reason;
      _pendingCloseReason = reason;
      return;
    }
    if (_closeHandled && (_reconnectTimer?.isActive ?? false)) {
      // Waiting out a backoff after a disconnect that was already reported
      // once: do not report it again, and keep the recorded close reason so
      // the next Connect still carries the real cause. Only the wait itself
      // is replaced, by the short client-initiated delay (not by the 0ms
      // connectivity-restore path).
      _log(
        DartvexLogLevel.info,
        'Replacing pending reconnect backoff with the client-initiated delay',
      );
      _scheduleReconnect(clientInitiated: true, manual: true);
      return;
    }
    _chunkBuffer = null;
    _lastCloseReason = reason;
    await _handleSyntheticDisconnect(reason, clientInitiated: true);
  }

  /// Cancels any pending reconnect backoff and reconnects immediately, but only
  /// while the manager is waiting to reconnect (disconnected with a scheduled
  /// retry).
  ///
  /// No-op when connected, mid-connect, stopped, or disposed. Used to react to
  /// a restored network connection without resetting the backoff progression.
  /// Once the reconnect's handshake completes, a `NetworkRecoveryReconnect`
  /// event reporting the skipped wait is sent, as the official client does.
  void reconnectImmediatelyIfWaiting() {
    if (_disposed || _stopped || _connecting || adapter.isConnected) {
      return;
    }
    final timer = _reconnectTimer;
    if (timer == null || !timer.isActive) {
      return;
    }
    final scheduledAt = _reconnectScheduledAtMs;
    if (scheduledAt != null) {
      final elapsed = _clock.nowMillis - scheduledAt;
      _pendingNetworkRecoveryTimeSavedMs =
          max(0, _reconnectScheduledDelayMs - elapsed);
    }
    _log(
      DartvexLogLevel.info,
      'Reconnecting immediately after connectivity restore',
    );
    _scheduleReconnect(immediate: true);
  }

  /// Disposes timers, subscriptions, and the underlying socket.
  Future<void> dispose() async {
    await _shutdown(DartvexLogLevel.debug, 'Disposing WebSocket manager');
  }

  /// Permanently closes the socket and prevents any future reconnect.
  ///
  /// Used when the server reports an unrecoverable `FatalError`: unlike a normal
  /// disconnect, no reconnect is scheduled. Reuses the same guard as [dispose],
  /// so the close it triggers cannot reschedule a connection.
  Future<void> terminate() async {
    if (_disposed) {
      return;
    }
    await _shutdown(
      DartvexLogLevel.warn,
      'Terminating WebSocket manager; no reconnect will be scheduled',
    );
  }

  Future<void> _shutdown(DartvexLogLevel level, String message) async {
    _disposed = true;
    _log(level, message);
    _reconnectTimer?.cancel();
    _inactivityTimer?.cancel();
    _chunkBuffer = null;
    await _messageSubscription?.cancel();
    await _closeSubscription?.cancel();
    await _closeAdapterBestEffort(
      'Failed to close WebSocket during shutdown',
    );
  }

  /// Appends [step] to the serialized message chain.
  ///
  /// The step catches everything itself, so the chain can never become an
  /// errored future that would silently skip every later message.
  void _enqueue(Future<void> Function() step) {
    _messageQueue = _messageQueue.then((_) async {
      try {
        await step();
      } catch (error, stackTrace) {
        // The steps already contain their own error handling; this guard only
        // keeps the serialization chain alive so a later failure cannot block
        // all subsequent messages.
        _log(
          DartvexLogLevel.error,
          'Unhandled error while processing WebSocket event',
          error: error,
          stackTrace: stackTrace,
        );
      }
    });
  }

  void _attachListeners() {
    _messageSubscription ??= adapter.messages.listen((raw) {
      // Tag the frame with the connection it arrived on. A frame still queued
      // when that connection is torn down (stop() for a reauth, a handled
      // close, a client-initiated reconnect) is dropped instead of being
      // applied to the next session, whose state the handshake has reset —
      // the official client gets the same effect by detaching `onmessage`
      // from a socket it closes.
      final epoch = _socketEpoch;
      _enqueue(() => _handleRawMessage(raw, epoch));
    }, onError: (Object error, StackTrace stackTrace) {
      unawaited(
        _handleAdapterStreamError(
          reason: 'WebSocketMessageStreamError',
          message: 'WebSocket message stream failed',
          error: error,
          stackTrace: stackTrace,
        ),
      );
    });
    _closeSubscription ??= adapter.closeEvents.listen((event) {
      // Behind any frames already queued, so they are handled first.
      _enqueue(() => _handleClosed(event));
    }, onError: (Object error, StackTrace stackTrace) {
      unawaited(
        _handleAdapterStreamError(
          reason: 'WebSocketCloseStreamError',
          message: 'WebSocket close stream failed',
          error: error,
          stackTrace: stackTrace,
        ),
      );
    });
  }

  Future<void> _handleAdapterStreamError({
    required String reason,
    required String message,
    required Object error,
    required StackTrace stackTrace,
  }) async {
    if (_disposed || _closeHandled || _stopped) {
      return;
    }
    _lastCloseReason = reason;
    _pendingCloseReason = reason;
    _chunkBuffer = null;
    if (_connecting) {
      // Supersede a connect continuation that might complete after this stream
      // error; otherwise it could run a handshake after this path has already
      // scheduled a replacement connection.
      _connectAttempt += 1;
      _connecting = false;
    }
    _log(
      DartvexLogLevel.error,
      message,
      error: error,
      stackTrace: stackTrace,
    );
    try {
      // Call close even when the adapter is not yet "connected": the built-in
      // adapters use close() to supersede and later discard a half-open
      // connect attempt.
      await adapter.close();
    } catch (closeError, closeStackTrace) {
      _log(
        DartvexLogLevel.error,
        'Failed to close WebSocket after stream error',
        error: closeError,
        stackTrace: closeStackTrace,
      );
    }
    await _handleSyntheticDisconnect(reason, clientInitiated: true);
  }

  Future<void> _connect() async {
    if (_disposed || _connecting) {
      return;
    }
    _connecting = true;
    _closeHandled = false;
    final attempt = ++_connectAttempt;
    _socketEpoch += 1;
    try {
      // Inside the try: user-supplied callbacks (the logger, the connection
      // state listener) must not be able to leave _connecting stuck at true,
      // which would make every later reconnect a silent no-op.
      _log(
        DartvexLogLevel.info,
        'Connecting WebSocket',
        data: <String, Object?>{'deploymentUrl': deploymentUrl},
      );
      onConnectionStateChanged(false, true);
      await adapter.connect(_buildWebSocketUrl()).timeout(connectTimeout);
      if (attempt != _connectAttempt) {
        // stop() superseded this attempt while the socket was opening; its
        // adapter close discards the late socket, and a restart() may already
        // be driving a newer attempt. Touch nothing — not even _connecting —
        // and especially do not run the handshake: it would send a second
        // Connect frame on whichever socket the adapter now fronts.
        return;
      }
      if (_disposed || _stopped) {
        _connecting = false;
        await _closeAdapterBestEffort(
          'Failed to close WebSocket after cancelled connect',
        );
        return;
      }
      if (!adapter.isConnected) {
        // connect() returned without an open socket — e.g. a close() that
        // raced the handshake made the adapter discard the late socket. No
        // close event will ever arrive for it, so treat the attempt as failed
        // here; returning quietly would leave the manager with nothing
        // connected and nothing scheduled.
        throw StateError('WebSocket was not open after connect completed');
      }
      _connecting = false;
      _pendingCloseReason = null;
      _cancelReconnectTimer();
      _resetInactivityTimer();
      _log(DartvexLogLevel.info, 'WebSocket connected');
      if (_pauseState != _SocketPauseState.no) {
        // The socket opened while paused: defer the Connect handshake and
        // subscription replay to resume() so they cannot race a pending auth.
        // Checked against `no` (not `yes`) defensively: `uninitialized` here
        // would mean a previous paused socket's state leaked across a close,
        // and running the handshake in that state would send it on a socket
        // the pause owner still believes is gated — sendMessages would
        // swallow the session-restoring messages and resume() would later
        // send a second Connect frame on this socket.
        _pauseState = _SocketPauseState.uninitialized;
        _log(
          DartvexLogLevel.debug,
          'WebSocket connected while paused; deferring handshake until resume',
        );
        return;
      }
      final handshakeSent = await _sendInitialMessages();
      if (!handshakeSent || !adapter.isConnected) {
        return;
      }
      _markConnected();
    } catch (error) {
      if (attempt != _connectAttempt) {
        // A superseded attempt's failure is not this manager's disconnect: the
        // stop()/restart() that superseded it owns the connection lifecycle
        // now, and running _handleClosed here would schedule a reconnect (or
        // clobber _connecting) on top of the newer attempt.
        return;
      }
      if (!_connecting) {
        // The socket had already opened: the failure came from the handshake
        // (for example a throwing session-restore builder), so this socket
        // may be open without its session. Force a clean client-initiated
        // reconnect instead of misreporting it as a failed connect.
        _log(
          DartvexLogLevel.error,
          'WebSocket handshake failed',
          error: error,
        );
        _lastCloseReason = 'HandshakeFailed';
        _pendingCloseReason = _lastCloseReason;
        await _closeOrSyntheticDisconnect(_lastCloseReason!,
            clientInitiated: true);
        return;
      }
      _connecting = false;
      final timedOut = error is TimeoutException;
      if (timedOut) {
        // Abort the half-open connect so it cannot open in the background after
        // we have already moved on to scheduling a reconnect.
        await _closeAdapterBestEffort(
          'Failed to close timed-out WebSocket connect',
        );
      }
      _log(
        DartvexLogLevel.error,
        'WebSocket connection failed',
        error: error,
      );
      await _handleClosed(
        WebSocketCloseEvent(
          errorMessage: timedOut
              ? 'ConnectTimeout after ${connectTimeout.inMilliseconds}ms'
              : error.toString(),
        ),
        connectFailure: true,
      );
    }
  }

  /// Sends the post-connect handshake: the [Connect] message followed by the
  /// session-restoring messages built by [onConnected].
  ///
  /// Returns whether the handshake completed on the socket it started on. A
  /// failed `Connect` send is handled like any other failed send (a
  /// `FailedToSendMessage` reconnect), and an asynchronous [onConnected] whose
  /// socket was replaced meanwhile is abandoned rather than replayed onto the
  /// newer socket.
  Future<bool> _sendInitialMessages() async {
    if (!adapter.isConnected) {
      _log(
        DartvexLogLevel.debug,
        'Skipping WebSocket handshake because the socket is no longer open',
      );
      return false;
    }
    final epoch = _socketEpoch;
    try {
      adapter.send(
        jsonEncode(
          Connect(
            sessionId: _sessionId,
            connectionCount: _connectionCount,
            lastCloseReason: _lastCloseReason,
            maxObservedTimestamp: maxObservedTimestamp(),
            clientTs: _clock.nowMillis,
          ).toJson(),
        ),
      );
    } catch (error, stackTrace) {
      _lastCloseReason = 'FailedToSendMessage';
      _pendingCloseReason = _lastCloseReason;
      _log(
        DartvexLogLevel.error,
        'Failed to send WebSocket Connect message',
        error: error,
        stackTrace: stackTrace,
      );
      await _closeOrSyntheticDisconnect(_lastCloseReason!,
          clientInitiated: true);
      return false;
    }
    // The reason has been reported to the server; the next one starts fresh.
    _lastCloseReason = null;
    // Resolve synchronously when possible: the production [onConnected]
    // (BaseClient.prepareReconnect) returns its messages synchronously, and
    // yielding to the event loop between the Connect frame and the
    // session-restoring messages would open a window where a concurrent
    // pause() makes [sendMessages] swallow them — the query set and replayed
    // requests they carry are only rebuilt on the next reconnect, leaving
    // this connection without any active queries until then.
    final messagesOrFuture = onConnected();
    final List<ClientMessage> reconnectMessages;
    if (messagesOrFuture is List<ClientMessage>) {
      reconnectMessages = messagesOrFuture;
    } else {
      reconnectMessages = await messagesOrFuture;
      if (epoch != _socketEpoch || !adapter.isConnected) {
        // The socket this handshake started on was torn down while the
        // asynchronous builder ran; the replacement socket runs (or ran) its
        // own full handshake, so these messages must not be sent onto it.
        return false;
      }
      if (_pauseState != _SocketPauseState.no) {
        // Paused while an asynchronous [onConnected] was building the
        // handshake messages, with the Connect frame already on the wire.
        // They cannot be buffered here, and resume() must not replay a second
        // Connect on this socket, so force a clean reconnect: the fresh
        // socket opens paused and defers its full handshake to resume().
        _log(
          DartvexLogLevel.warn,
          'Socket paused during the connect handshake; forcing a clean '
          'reconnect so the session-restoring messages are not dropped',
        );
        await reconnectNow('PausedDuringHandshake');
        return false;
      }
    }
    await sendMessages(reconnectMessages);
    if (epoch != _socketEpoch || !adapter.isConnected) {
      return false;
    }
    _sendNetworkRecoveryEventIfPending();
    return true;
  }

  /// Reports the backoff time a connectivity-restore reconnect skipped, as the
  /// official client's `NetworkRecoveryReconnect` event.
  void _sendNetworkRecoveryEventIfPending() {
    final timeSavedMs = _pendingNetworkRecoveryTimeSavedMs;
    if (timeSavedMs == null) {
      return;
    }
    _pendingNetworkRecoveryTimeSavedMs = null;
    _log(
      DartvexLogLevel.info,
      'Network recovery reconnect skipped part of the backoff',
      data: <String, Object?>{'timeSavedMs': timeSavedMs},
    );
    unawaited(
      sendMessages(<ClientMessage>[
        Event(
          eventType: 'NetworkRecoveryReconnect',
          event: <String, Object?>{'timeSavedMs': timeSavedMs},
        ),
      ]),
    );
  }

  /// Pauses the socket so [sendMessages] buffers instead of sending.
  ///
  /// Used while auth is resolved on the initial token fetch so queries and
  /// mutations cannot race ahead of a pending auth. A socket that opens while
  /// paused defers its handshake until [resume]. No-op once disposed.
  void pause() {
    if (_disposed || _pauseState != _SocketPauseState.no) {
      return;
    }
    _pauseState = _SocketPauseState.yes;
    _log(DartvexLogLevel.debug, 'WebSocket paused for auth');
  }

  /// Resumes a previously [pause]d socket.
  ///
  /// If the socket opened while paused, the deferred handshake runs now;
  /// otherwise the messages buffered by [onResume] are flushed in order. No-op
  /// if not paused or disposed.
  Future<void> resume() async {
    if (_disposed) {
      return;
    }
    switch (_pauseState) {
      case _SocketPauseState.no:
        return;
      case _SocketPauseState.uninitialized:
        _pauseState = _SocketPauseState.no;
        _log(
            DartvexLogLevel.debug,
            'Resuming WebSocket; running deferred '
            'handshake');
        final handshakeSent = await _sendInitialMessages();
        if (handshakeSent && adapter.isConnected) {
          _markConnected();
        }
      case _SocketPauseState.yes:
        _pauseState = _SocketPauseState.no;
        _log(
            DartvexLogLevel.debug,
            'Resuming WebSocket; flushing buffered '
            'messages');
        if (onResume != null) {
          // Resolve synchronously when possible: the production [onResume]
          // (BaseClient.resume) drains the base client synchronously, and
          // yielding to the event loop between that drain and [sendMessages]
          // would open a window where a concurrent pause() makes
          // [sendMessages] drop the drained messages on a live connection —
          // the deferred auth, the resume query-set delta, and any drained
          // requests would only be rebuilt by the next reconnect.
          final epoch = _socketEpoch;
          final messagesOrFuture = onResume!();
          final List<ClientMessage> messages;
          if (messagesOrFuture is List<ClientMessage>) {
            messages = messagesOrFuture;
          } else {
            messages = await messagesOrFuture;
            if (epoch != _socketEpoch) {
              // The connection changed while the asynchronous [onResume]
              // ran; the new connection's handshake rebuilds the query set,
              // auth, and unsent requests, so these must not be replayed onto
              // it.
              return;
            }
            if (_pauseState != _SocketPauseState.no) {
              // Paused again while an asynchronous [onResume] was building
              // the messages. They are already drained out of the base client
              // and cannot be buffered here, so force a clean reconnect: the
              // fresh socket opens paused and defers its handshake to the new
              // pause owner's resume, which rebuilds the query set, auth, and
              // unsent requests losslessly.
              _log(
                DartvexLogLevel.warn,
                'Socket paused during resume; forcing a clean reconnect so '
                'the resumed messages are not dropped',
              );
              await reconnectNow('PausedDuringResume');
              return;
            }
          }
          await sendMessages(messages);
        }
    }
  }

  /// Closes the socket without scheduling a reconnect.
  ///
  /// Used during a reauth so in-flight messages do not retry with stale auth;
  /// the connection is re-established by [restart] (which replays the session
  /// with the refreshed token). Publishes a disconnected state when a
  /// connection was open or opening, so the coarse connection state agrees
  /// with [isConnected] while the reauth's token fetch runs. No-op once
  /// disposed.
  Future<void> stop() async {
    if (_disposed) {
      return;
    }
    _log(DartvexLogLevel.debug, 'Stopping WebSocket for reauth');
    final wasLive = adapter.isConnected || _connecting;
    _stopped = true;
    _pauseState = _SocketPauseState.no;
    _connecting = false;
    // Supersede any in-flight connect attempt so its continuation bails out
    // instead of completing a handshake the restart() will redo on a fresh
    // socket. Mirrors the official client's stop(), which detaches and closes
    // a "connecting" socket.
    final stopAttempt = ++_connectAttempt;
    // Frames still queued from the stopped socket must not be applied to the
    // session restart() rebuilds.
    _socketEpoch += 1;
    _cancelReconnectTimer();
    _inactivityTimer?.cancel();
    _chunkBuffer = null;
    // Close unconditionally: when a connect is mid-flight the adapter is not
    // "connected" yet, but close() makes the built-in adapters discard the
    // late socket (native: by advancing its connect generation; web: by
    // failing the pending connect) instead of letting it open unmanaged while
    // stopped. Closing an idle adapter is a no-op. _handleClosed sees _stopped
    // and skips its reconnect bookkeeping; restart() rebuilds the session.
    await _closeAdapterBestEffort(
      'Failed to close WebSocket while stopping for reauth',
    );
    // A slow close handshake can outlive the stop: a superseding restart()
    // (or another stop/restart cycle) may already have reconnected, and a late
    // "disconnected" would then contradict the live connection. Publish only
    // while this stop is still the latest word on the connection.
    if (wasLive && !_disposed && _stopped && stopAttempt == _connectAttempt) {
      onConnectionStateChanged(false, false);
    }
  }

  /// Re-establishes the connection after [stop]. No-op unless stopped.
  Future<void> restart() async {
    if (_disposed || !_stopped) {
      return;
    }
    _log(DartvexLogLevel.debug, 'Restarting WebSocket after reauth');
    _stopped = false;
    await _connect();
  }

  String _buildWebSocketUrl() {
    final uri = Uri.parse(deploymentUrl);
    final wsScheme = switch (uri.scheme) {
      'http' => 'ws',
      'ws' => 'ws',
      'wss' => 'wss',
      _ => 'wss',
    };
    return uri
        .replace(
          scheme: wsScheme,
          path: '/api/$apiVersion/sync',
          query: null,
          fragment: null,
        )
        .toString();
  }

  Future<void> _handleRawMessage(String raw, int epoch) async {
    if (_disposed) {
      return;
    }
    if (epoch != _socketEpoch) {
      // Queued from a connection that has since been torn down.
      _log(
        DartvexLogLevel.debug,
        'Dropping WebSocket frame from a superseded connection',
      );
      return;
    }
    try {
      if (adapter.isConnected) {
        // Only a live connection re-arms the liveness timer; a frame handled
        // after its connection went away must not arm a timer that would
        // later close whatever the adapter fronts by then.
        _resetInactivityTimer();
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw FormatException('Server message must be an object', raw);
      }
      var message = ServerMessage.fromJson(decoded);
      if (message is Ping) {
        return;
      }
      if (message is TransitionChunk) {
        final assembledTransition = _appendTransitionChunk(message);
        if (assembledTransition == null) {
          return;
        }
        _reportTransitionMetrics(
          assembledTransition.transition,
          assembledTransition.rawMessage,
        );
        message = assembledTransition.transition;
      } else {
        if (_chunkBuffer != null) {
          _chunkBuffer = null;
          _log(
            DartvexLogLevel.warn,
            'Received non-chunk message while buffering TransitionChunks',
            data: <String, Object?>{'type': decoded['type']},
          );
        }
        if (message is Transition) {
          _reportTransitionMetrics(message, raw);
        }
      }
      await onMessage(message);
      // Reset the reconnect backoff only once the client has caught up on all
      // work that predated the last reconnect, rather than on every Transition
      // or response. This mirrors the official client and prevents a flapping
      // server from resetting the backoff before the connection proves itself.
      if (hasSyncedPastLastReconnect()) {
        _resetRetries();
      }
    } catch (error, stackTrace) {
      _chunkBuffer = null;
      _lastCloseReason = 'InvalidServerMessage';
      _pendingCloseReason = _lastCloseReason;
      _log(
        DartvexLogLevel.error,
        'Failed to handle WebSocket message',
        error: error,
        stackTrace: stackTrace,
      );
      await _closeOrSyntheticDisconnect(_lastCloseReason!,
          clientInitiated: true);
    }
  }

  void _resetRetries() {
    if (_reconnectIndex == 0 && _connectionRetries == 0) {
      return;
    }
    _reconnectIndex = 0;
    _connectionRetries = 0;
    _notifyStatusChanged();
  }

  void _notifyStatusChanged() {
    final callback = onStatusChanged;
    if (callback == null) {
      return;
    }
    try {
      callback();
    } catch (error, stackTrace) {
      _log(
        DartvexLogLevel.error,
        'Connection status listener threw',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  _AssembledTransition? _appendTransitionChunk(TransitionChunk chunk) {
    final buffer = _chunkBuffer;
    if (chunk.totalParts <= 0 ||
        chunk.partNumber < 0 ||
        chunk.partNumber >= chunk.totalParts ||
        (buffer != null &&
            (buffer.totalParts != chunk.totalParts ||
                buffer.transitionId != chunk.transitionId))) {
      _chunkBuffer = null;
      throw FormatException('Invalid TransitionChunk', chunk.toJson());
    }

    final activeBuffer = buffer ??
        (_chunkBuffer = _TransitionChunkBuffer(
          totalParts: chunk.totalParts,
          transitionId: chunk.transitionId,
        ));

    if (chunk.partNumber != activeBuffer.parts.length) {
      final expectedPart = activeBuffer.parts.length;
      _chunkBuffer = null;
      throw FormatException(
        'TransitionChunk received out of order: expected part '
        '$expectedPart, got ${chunk.partNumber}',
        chunk.toJson(),
      );
    }

    activeBuffer.parts.add(chunk.chunk);
    if (activeBuffer.parts.length != activeBuffer.totalParts) {
      return null;
    }

    final assembled = activeBuffer.parts.join();
    _chunkBuffer = null;
    final decoded = jsonDecode(assembled);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException(
          'Assembled Transition must be an object', assembled);
    }
    final message = ServerMessage.fromJson(decoded);
    if (message is! Transition) {
      throw FormatException(
        'Expected Transition after assembling chunks, got ${decoded['type']}',
        decoded,
      );
    }
    return _AssembledTransition(transition: message, rawMessage: assembled);
  }

  /// Size threshold above which a Transition is logged as oversized.
  static const int _oversizedTransitionBytes = 20000000;

  /// Transit time above which a Transition is logged as slow.
  static const double _slowTransitionMs = 20000;

  void _reportTransitionMetrics(Transition transition, String rawMessage) {
    if (transition.clientClockSkew == null || transition.serverTs == null) {
      return;
    }
    final callback = onTransitionMetrics;
    final warnEnabled = logger != null &&
        shouldEmitDartvexLog(
          configuredLevel: logLevel,
          eventLevel: DartvexLogLevel.warn,
        );
    if (callback == null && !warnEnabled) {
      // Nobody consumes the numbers; skip measuring the message entirely.
      return;
    }

    final nowMs = _clock.nowMillis.toDouble();
    final transitTimeMs =
        nowMs - transition.clientClockSkew! - transition.serverTs! / 1e6;
    if (transitTimeMs <= 0) {
      return;
    }

    // Counted without allocating a UTF-8 copy of a potentially huge message.
    final messageLengthBytes = utf8EncodedLength(rawMessage);
    if (callback != null) {
      final metrics = TransitionMetrics(
        transitTimeMs: transitTimeMs,
        messageSizeBytes: messageLengthBytes,
        bytesPerSecond: messageLengthBytes / (transitTimeMs / 1000),
      );
      try {
        callback(metrics);
      } catch (error, stackTrace) {
        // User code: a throwing metrics callback must not be classified as an
        // invalid server message (which would drop this Transition and force a
        // reconnect on every subsequent one).
        _log(
          DartvexLogLevel.error,
          'onTransitionMetrics callback threw',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    if (messageLengthBytes > _oversizedTransitionBytes) {
      _log(
        DartvexLogLevel.warn,
        'Received oversized transition',
        data: <String, Object?>{
          'messageSizeBytes': messageLengthBytes,
          'messageSizeMb': double.parse(
            (messageLengthBytes / 1e6).toStringAsFixed(1),
          ),
        },
      );
    } else if (transitTimeMs > _slowTransitionMs) {
      _log(
        DartvexLogLevel.warn,
        'Transition arrived slowly',
        data: <String, Object?>{
          'transitTimeMs': transitTimeMs.round(),
          'messageSizeBytes': messageLengthBytes,
        },
      );
    }
  }

  /// Returns the number of bytes [value] occupies when UTF-8 encoded, without
  /// allocating the encoding.
  ///
  /// Matches `utf8.encode(value).length`, including the 3-byte replacement
  /// character that the encoder substitutes for an unpaired surrogate.
  @visibleForTesting
  static int utf8EncodedLength(String value) {
    var length = 0;
    final codeUnits = value.length;
    for (var i = 0; i < codeUnits; i++) {
      final unit = value.codeUnitAt(i);
      if (unit < 0x80) {
        length += 1;
      } else if (unit < 0x800) {
        length += 2;
      } else if (unit >= 0xD800 &&
          unit <= 0xDBFF &&
          i + 1 < codeUnits &&
          (value.codeUnitAt(i + 1) & 0xFC00) == 0xDC00) {
        // A surrogate pair encodes one supplementary code point (4 bytes).
        length += 4;
        i += 1;
      } else {
        length += 3;
      }
    }
    return length;
  }

  Future<void> _handleClosed(
    WebSocketCloseEvent event, {
    bool connectFailure = false,
  }) async {
    if (_disposed || _closeHandled || _stopped) {
      // A stop() close is deliberate: restart() will rebuild the session, so we
      // must not run the disconnect bookkeeping or schedule a reconnect here.
      return;
    }
    if (adapter.isConnected || _connecting) {
      // Both adapters null their current socket before emitting its close
      // event, so a close delivered while the adapter fronts an open socket
      // can only come from a superseded socket whose teardown outlived the
      // next connect — e.g. a native close that timed out on a dead network
      // and was force-destroyed by the platform seconds later, after a
      // connectivity-restore reconnect already succeeded. Running the
      // disconnect bookkeeping here would tear down that healthy successor
      // connection. The official client cannot reach this state because it
      // detaches the close handler from sockets it closes deliberately.
      //
      // The same applies while a connect attempt is in flight: a stale close
      // landing in that window would consume _closeHandled, and once the
      // attempt succeeds the poisoned flag would make the new connection's
      // next real close a silent no-op — no reconnect would ever be
      // scheduled again. The in-flight socket itself cannot be silenced by
      // this guard: the native adapter only registers its close listener
      // after connect() resolves, and a web socket that closes mid-connect
      // also fails the connect future, whose catch drives _handleClosed
      // after clearing _connecting.
      _log(
        DartvexLogLevel.debug,
        'Ignoring close event from a superseded socket',
        data: <String, Object?>{
          if (event.code != null) 'code': event.code,
          if (event.reason != null && event.reason!.isNotEmpty)
            'closeReason': event.reason,
        },
      );
      return;
    }
    _closeHandled = true;
    _socketEpoch += 1;
    if (_pauseState == _SocketPauseState.uninitialized) {
      // `uninitialized` means "the current socket opened while paused and its
      // handshake is deferred to resume()". That socket is gone, so revert to
      // the plain paused state: the next reconnect must defer its handshake
      // again rather than treat the dead socket's deferral as already
      // resolved (which would run the handshake while paused, swallowing the
      // session-restoring messages, and let resume() send a second Connect
      // frame on the new socket).
      _pauseState = _SocketPauseState.yes;
    }
    // A close the client itself initiated (reconnectNow, a detected
    // protocol error, an inactivity timeout) sets _pendingCloseReason first; an
    // unexpected server/network close leaves it null. Client-initiated
    // reconnects back off from the official 100ms base, while a server/network
    // close uses the reason-classified (overload table / 1s) base.
    final clientInitiated = _pendingCloseReason != null;
    final reason = _pendingCloseReason ?? event.diagnosticReason;
    _pendingCloseReason = null;
    _log(
      DartvexLogLevel.info,
      'WebSocket closed',
      data: <String, Object?>{
        'reason': reason,
        if (event.code != null) 'code': event.code,
        if (event.reason != null && event.reason!.isNotEmpty)
          'closeReason': event.reason,
        if (event.wasClean != null) 'wasClean': event.wasClean,
        if (event.errorMessage != null && event.errorMessage!.isNotEmpty)
          'errorMessage': event.errorMessage,
      },
    );
    if (clientInitiated) {
      _lastCloseReason = reason;
    } else {
      // Keep the first reason across failed reconnect attempts, as the
      // official client's onclose does.
      _lastCloseReason ??= reason;
    }
    if (!clientInitiated && !connectFailure) {
      _reportServerDisconnectError(event);
    }
    _inactivityTimer?.cancel();
    _chunkBuffer = null;
    _connecting = false;
    onConnectionStateChanged(false, false);
    await onDisconnected(reason);
    _scheduleReconnect(clientInitiated: clientInitiated, reason: reason);
  }

  void _reportServerDisconnectError(WebSocketCloseEvent event) {
    final callback = onServerDisconnectError;
    final closeReason = event.reason;
    if (callback == null ||
        closeReason == null ||
        closeReason.isEmpty ||
        _expectedCloseCodes.contains(event.code)) {
      return;
    }
    final message = event.code == null
        ? 'WebSocket closed: $closeReason'
        : 'WebSocket closed with code ${event.code}: $closeReason';
    try {
      callback(message);
    } catch (error, stackTrace) {
      _log(
        DartvexLogLevel.error,
        'onServerDisconnectError callback threw',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Handles a disconnect with no real socket close event to drive it.
  ///
  /// Only ever reached on a client-initiated reconnect path (a forced
  /// reconnect, a detected error, an inactivity timeout, or a close the client
  /// issued itself), so the reconnect uses the client backoff base by default.
  Future<void> _handleSyntheticDisconnect(
    String reason, {
    bool clientInitiated = true,
  }) async {
    if (_disposed || _closeHandled || _stopped) {
      return;
    }
    _closeHandled = true;
    _socketEpoch += 1;
    if (_pauseState == _SocketPauseState.uninitialized) {
      // See _handleClosed: the socket whose handshake was deferred is gone,
      // so the next socket must defer its handshake to resume() again.
      _pauseState = _SocketPauseState.yes;
    }
    _pendingCloseReason = null;
    _log(
      DartvexLogLevel.info,
      'WebSocket disconnected',
      data: <String, Object?>{'reason': reason},
    );
    _lastCloseReason = reason;
    _inactivityTimer?.cancel();
    _chunkBuffer = null;
    _connecting = false;
    onConnectionStateChanged(false, false);
    await onDisconnected(reason);
    _scheduleReconnect(clientInitiated: clientInitiated, reason: reason);
  }

  /// Closes the current socket and runs the disconnect bookkeeping right away,
  /// without waiting for the platform's close event.
  ///
  /// Mirrors the official client's `closeAndReconnect`: on a dead connection
  /// the close event only arrives after the platform's closing-handshake
  /// timeout (up to a minute in browsers), and nothing would reconnect, fail
  /// in-flight requests, or report the disconnect until then. The late close
  /// event is discarded by [_handleClosed]'s guards (`_closeHandled`, an open
  /// successor socket, or an in-flight connect).
  Future<void> _closeOrSyntheticDisconnect(
    String reason, {
    required bool clientInitiated,
  }) async {
    // The socket this cleanup is for. A close handshake can be slow: its real
    // close event may already have run the disconnect bookkeeping, and the
    // reconnect it scheduled may already have opened (and replayed the
    // session onto) a replacement socket by the time close() returns.
    final epoch = _socketEpoch;
    if (adapter.isConnected) {
      try {
        await adapter.close();
      } catch (error, stackTrace) {
        _log(
          DartvexLogLevel.error,
          'Failed to close WebSocket before reconnect',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    if (epoch != _socketEpoch) {
      // The closed socket's disconnect was already handled (or a stop or a
      // newer connection superseded it); a synthetic disconnect now would
      // tear down the successor connection and fail its in-flight actions.
      _log(
        DartvexLogLevel.debug,
        'Skipping the synthetic disconnect of an already superseded socket',
      );
      return;
    }
    await _handleSyntheticDisconnect(reason, clientInitiated: clientInitiated);
  }

  Future<void> _closeAdapterBestEffort(String message) async {
    try {
      await adapter.close();
    } catch (error, stackTrace) {
      _log(
        DartvexLogLevel.error,
        message,
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _cancelReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _reconnectScheduledAtMs = null;
  }

  /// Schedules the next connect attempt.
  ///
  /// [reason] classifies a server/network close against the overload table.
  /// [manual] marks an explicit [reconnectNow] that replaces a pending backoff
  /// wait: it uses the first client-initiated delay without advancing the
  /// backoff progression, so a failure afterwards resumes where it left off.
  void _scheduleReconnect({
    bool immediate = false,
    bool clientInitiated = false,
    bool manual = false,
    String? reason,
  }) {
    if (_disposed) {
      return;
    }
    _cancelReconnectTimer();
    final delay = _nextReconnectDelay(
      immediate: immediate,
      clientInitiated: clientInitiated || manual,
      manual: manual,
      reason: reason ?? '',
    );
    _log(
      DartvexLogLevel.info,
      'Reconnect scheduled',
      data: <String, Object?>{
        'delayMs': delay.inMilliseconds,
        'connectionCount': _connectionCount,
        'reason': _lastCloseReason ?? reason,
      },
    );
    _reconnectScheduledAtMs = _clock.nowMillis;
    _reconnectScheduledDelayMs = delay.inMilliseconds;
    _reconnectTimer = Timer(delay, () {
      _reconnectScheduledAtMs = null;
      unawaited(_connect());
    });
    _notifyStatusChanged();
  }

  /// Computes the next reconnect delay and advances the retry counters.
  ///
  /// With an empty [reconnectBackoff] schedule, an exponential backoff with
  /// jitter is derived from [maxBackoff], [backoffJitter], and a base that
  /// depends on who triggered the reconnect: the official 100ms client base
  /// when [clientInitiated] (a forced reconnect or a client-detected error),
  /// otherwise the base classified from [reason] (the server-overload table,
  /// or [initialBackoff] for an unclassified close).
  ///
  /// A non-empty [reconnectBackoff] schedule is used verbatim (no jitter) for
  /// server/network closes. A client-initiated reconnect uses the 100ms
  /// client base (doubling per retry, no jitter) but never waits longer than
  /// the schedule's entry, so [reconnectNow] stays prompt under a long fixed
  /// schedule.
  Duration _nextReconnectDelay({
    required bool immediate,
    required bool clientInitiated,
    required bool manual,
    required String reason,
  }) {
    if (immediate) {
      return Duration.zero;
    }
    final retries = manual ? 0 : _connectionRetries;
    if (!manual) {
      _connectionRetries += 1;
    }
    if (reconnectBackoff.isNotEmpty) {
      final index = min(_reconnectIndex, reconnectBackoff.length - 1);
      if (!manual && _reconnectIndex < reconnectBackoff.length - 1) {
        _reconnectIndex += 1;
      }
      final scheduled = reconnectBackoff[index];
      if (!clientInitiated) {
        return scheduled;
      }
      return computeExponentialBackoff(
        retryIndex: retries,
        baseBackoffMs: _clientReconnectInitialBackoffMs,
        maxBackoffMs: scheduled.inMilliseconds,
        jitter: 0,
        randomUnit: 0.5,
      );
    }
    final baseMs = clientInitiated
        ? _clientReconnectInitialBackoffMs
        : _classifiedInitialBackoffMs(reason);
    final delay = computeExponentialBackoff(
      retryIndex: manual ? 0 : _reconnectIndex,
      baseBackoffMs: baseMs,
      maxBackoffMs: maxBackoff.inMilliseconds,
      jitter: backoffJitter,
      randomUnit: _random.nextDouble(),
    );
    if (!manual) {
      _reconnectIndex += 1;
    }
    return delay;
  }

  /// Retry indexes above this saturate the exponential backoff anyway
  /// (`2^62` times any realistic base already exceeds every cap), so larger
  /// indexes are clamped before `pow` to keep the arithmetic finite.
  static const int _maxBackoffExponent = 62;

  /// Computes the jittered exponential reconnect delay for [retryIndex].
  ///
  /// The delay grows as `baseBackoffMs * 2^retryIndex`, is capped at
  /// [maxBackoffMs], then spread by ±[jitter] using [randomUnit] in `[0, 1)`.
  /// [baseBackoffMs] is the official 100ms client base for a client-initiated
  /// reconnect, otherwise the classified server/unknown base. Mirrors the
  /// official client's `nextBackoff`: `min(base * 2^retries, max)` then
  /// `+ actualBackoff * (random - 0.5)`. A double base (`pow(2.0, …)`) is used
  /// deliberately: an int `pow(2, retryIndex)` wraps a 64-bit integer to 0 at
  /// index 64 (and negative at 63), which would collapse the backoff to ~0 and
  /// hot-loop after a long unbroken run of failed reconnects. The exponent is
  /// additionally clamped, and a zero (or negative) base short-circuits to
  /// zero, so `0 * 2^1024` (`0 * Infinity`, i.e. NaN) can never reach
  /// `round()` and the cap always holds.
  @visibleForTesting
  static Duration computeExponentialBackoff({
    required int retryIndex,
    required int baseBackoffMs,
    required int maxBackoffMs,
    required double jitter,
    required double randomUnit,
  }) {
    if (baseBackoffMs <= 0 || maxBackoffMs <= 0) {
      return Duration.zero;
    }
    final exponent = retryIndex.clamp(0, _maxBackoffExponent);
    final exponentialMs = baseBackoffMs * pow(2.0, exponent);
    final cappedMs = min(exponentialMs, maxBackoffMs.toDouble());
    final jitterSpan = cappedMs * jitter * (randomUnit * 2 - 1);
    final delayMs = (cappedMs + jitterSpan).clamp(0.0, double.infinity);
    if (!delayMs.isFinite) {
      return Duration(milliseconds: maxBackoffMs);
    }
    return Duration(milliseconds: delayMs.round());
  }

  int _classifiedInitialBackoffMs(String reason) {
    for (final entry in _serverDisconnectBackoffMs.entries) {
      if (reason.startsWith(entry.key)) {
        return entry.value;
      }
    }
    return initialBackoff.inMilliseconds;
  }

  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    _inactivityTimer = Timer(inactivityTimeout, () async {
      // Only an open connection can go inactive. A timer that outlived its
      // connection (one that slipped past a teardown) must not close whatever
      // the adapter fronts now — closing an in-flight connect would make the
      // adapter discard it silently.
      if (_disposed || _stopped || !adapter.isConnected) {
        return;
      }
      const reason = 'InactiveServer';
      _lastCloseReason = reason;
      _pendingCloseReason = reason;
      _log(DartvexLogLevel.warn, 'Closing WebSocket after inactivity timeout');
      await _closeOrSyntheticDisconnect(reason, clientInitiated: true);
    });
  }

  void _log(
    DartvexLogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) {
    emitDartvexLog(
      configuredLevel: logLevel,
      logger: logger,
      eventLevel: level,
      message: message,
      tag: 'transport.ws',
      error: error,
      stackTrace: stackTrace,
      data: data,
    );
  }
}

class _TransitionChunkBuffer {
  _TransitionChunkBuffer({
    required this.totalParts,
    required this.transitionId,
  });

  final int totalParts;
  final String transitionId;
  final List<String> parts = <String>[];
}

class _AssembledTransition {
  const _AssembledTransition({
    required this.transition,
    required this.rawMessage,
  });

  final Transition transition;

  /// The reassembled raw JSON, measured lazily for metrics.
  final String rawMessage;
}
