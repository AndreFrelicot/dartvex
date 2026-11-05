// Derived from package:cupertino_http's CupertinoWebSocket
// (https://github.com/dart-lang/http, BSD-3-Clause, Dart project authors).
//
// Differences from upstream:
//
// * Every connection runs on ONE process-wide URLSession and sends its
//   per-client headers (`Convex-Client`) on the URLRequest instead of through
//   a per-connection URLSessionConfiguration. Upstream creates a fresh session
//   whenever a custom configuration is passed, and documents that a session
//   which has run a WebSocket task is never fully released, even after
//   invalidation (see dart-lang/http#1282 and the comment on
//   `CupertinoWebSocket._sharedSession`). A sync client reconnects
//   indefinitely, so a per-connection session would leak one native session
//   per reconnect; a single shared session leaks nothing per connection.
// * The shared session is cookie-less and ephemeral (see
//   [cookielessSessionConfiguration]).
// * The native task sits behind [CupertinoSocketTask], so the socket's
//   close/error state machine is unit-testable without NSURLSession.
// * Peer-controlled close reasons are decoded with `allowMalformed`, and
//   non-NSError failures surface as an abnormal close instead of throwing.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:meta/meta.dart';
import 'package:objective_c/objective_c.dart' as objc;
import 'package:web_socket/web_socket.dart';

/// A cookie-less, ephemeral NSURLSession configuration.
///
/// The SDK's HTTP and WebSocket traffic is bearer-token based, exactly like
/// the `dart:io` (Android, desktop) and fetch (web) transports, which never
/// send or store cookies. The default NSURLSession configuration instead
/// persists cookies in the shared `HTTPCookieStorage` and attaches them to
/// every later request: a Better Auth session cookie stored by a sign-in
/// response would then ride along on sign-out or the next sign-in (rejected
/// with 403 by Better Auth's origin/CSRF checks) and could even take
/// precedence over the explicit bearer token. The ephemeral configuration also
/// keeps caches and credentials in memory only, matching `dart:io`.
@internal
URLSessionConfiguration cookielessSessionConfiguration() {
  return URLSessionConfiguration.ephemeralSessionConfiguration()
    ..httpShouldSetCookies = false
    ..httpCookieAcceptPolicy =
        NSHTTPCookieAcceptPolicy.NSHTTPCookieAcceptPolicyNever;
}

/// A native WebSocket failure, decoupled from `NSError` so the socket logic
/// can be tested without the Objective-C runtime.
@visibleForTesting
class CupertinoTaskError implements Exception {
  /// Creates a task error from an NSError's domain, code and description.
  const CupertinoTaskError(this.domain, this.code, this.description);

  /// Converts a native [objc.NSError].
  factory CupertinoTaskError.fromNSError(objc.NSError error) {
    return CupertinoTaskError(
      error.domain.toDartString(),
      error.code,
      error.localizedDescription.toDartString(),
    );
  }

  /// The NSError domain, e.g. `NSPOSIXErrorDomain`.
  final String domain;

  /// The NSError code.
  final int code;

  /// The localized description.
  final String description;

  @override
  String toString() => 'CupertinoTaskError($domain $code: $description)';
}

/// The operations [CupertinoTaskWebSocket] needs from an
/// NSURLSessionWebSocketTask.
///
/// Native failures must surface as [CupertinoTaskError].
@visibleForTesting
abstract interface class CupertinoSocketTask {
  /// Receives the next message as [TextDataReceived] or [BinaryDataReceived].
  Future<WebSocketEvent> receive();

  /// Sends a text frame.
  Future<void> sendText(String text);

  /// Sends a binary frame.
  Future<void> sendBytes(Uint8List bytes);

  /// Cancels the task without a close frame.
  void cancel();

  /// Sends a close frame with [code] and [reason], then cancels the task.
  void cancelWithCloseCode(int code, Uint8List reason);
}

/// Tracks one connection attempt: resolves [future] with the socket once the
/// handshake succeeds, or rejects it when the task completes first.
///
/// Fed by the per-task NSURLSession delegate callbacks.
@visibleForTesting
class CupertinoConnectAttempt {
  final Completer<CupertinoTaskWebSocket> _ready =
      Completer<CupertinoTaskWebSocket>();
  CupertinoTaskWebSocket? _socket;

  /// Completes with the open socket, or fails with a [WebSocketException].
  Future<CupertinoTaskWebSocket> get future => _ready.future;

  /// `onWebSocketTaskOpened`: the handshake succeeded.
  void opened(CupertinoSocketTask task, String? protocol) {
    if (_ready.isCompleted) {
      return;
    }
    final socket = CupertinoTaskWebSocket(task, protocol ?? '');
    _socket = socket;
    _ready.complete(socket);
  }

  /// `onWebSocketTaskClosed`: the peer sent a close frame.
  void peerClosed(int? closeCode, List<int>? reason) {
    _socket?.handlePeerClose(closeCode, reason);
  }

  /// `onComplete`: the task ended, with [error] when it failed.
  void completed(CupertinoTaskError? error) {
    final socket = _socket;
    if (socket != null) {
      // Either side already closed (then this is a no-op) or the connection
      // dropped without a close handshake.
      socket.handleTaskComplete();
      return;
    }
    if (_ready.isCompleted) {
      return;
    }
    _ready.completeError(
      WebSocketException(
        error == null
            ? 'connection ended before the WebSocket handshake completed'
            : 'connection ended unexpectedly: ${error.description}',
      ),
    );
  }
}

/// A [WebSocket] over an NSURLSessionWebSocketTask that runs on a single,
/// process-wide, cookie-less URLSession.
class CupertinoTaskWebSocket implements WebSocket {
  /// Shared by every connection; never invalidated, so reconnects do not
  /// create (and leak) native sessions.
  static final URLSession _sharedSession = objc.autoReleasePool(
    () => URLSession.sessionWithConfiguration(cookielessSessionConfiguration()),
  );

  /// Opens a WebSocket connection to [url] (`ws`/`wss` only), sending
  /// [headers] with the handshake request.
  static Future<CupertinoTaskWebSocket> connect(
    Uri url, {
    Map<String, String> headers = const <String, String>{},
  }) {
    if (!url.isScheme('ws') && !url.isScheme('wss')) {
      throw ArgumentError.value(
        url,
        'url',
        'only ws: and wss: schemes are supported',
      );
    }
    final attempt = CupertinoConnectAttempt();
    // The autorelease pool reclaims the request/task objects Foundation
    // autoreleases while creating the task (it cannot span an async gap).
    objc.autoReleasePool(() {
      final request = MutableURLRequest.fromUrl(url);
      headers.forEach(
        (name, value) => request.setValueForHttpHeaderField(value, name),
      );
      _sharedSession.webSocketTaskWithRequest(request)
        ..taskDelegate = URLSessionTask.delegate(
          // Successful flow: onWebSocketTaskOpened, <messages>, optionally
          // onWebSocketTaskClosed (peer close frame), then onComplete.
          // Failed connect: onComplete(error) only. onComplete can also fire
          // at any time when the peer disappears without a close handshake.
          onWebSocketTaskOpened: (session, task, protocol) {
            attempt.opened(_UrlSessionSocketTask(task), protocol);
          },
          onWebSocketTaskClosed: (session, task, closeCode, reason) {
            attempt.peerClosed(closeCode, reason?.toList());
          },
          onComplete: (session, task, error) {
            attempt.completed(
              error == null ? null : CupertinoTaskError.fromNSError(error),
            );
          },
        )
        ..resume();
    });
    return attempt.future;
  }

  /// Creates a socket over an already-open [task].
  @visibleForTesting
  CupertinoTaskWebSocket(this._task, this._protocol) {
    _scheduleReceive();
  }

  final CupertinoSocketTask _task;
  final String _protocol;
  final StreamController<WebSocketEvent> _events =
      StreamController<WebSocketEvent>();

  void _handleMessage(WebSocketEvent event) {
    if (_events.isClosed) return;
    _events.add(event);
    _scheduleReceive();
  }

  void _scheduleReceive() {
    unawaited(
      _task.receive().then(_handleMessage, onError: _closeConnectionWithError),
    );
  }

  /// Closes the connection after a native receive/send failure and emits the
  /// matching [CloseReceived].
  void _closeConnectionWithError(Object error) {
    if (error is CupertinoTaskError) {
      if (error.domain == 'NSPOSIXErrorDomain' && error.code == 57) {
        // Socket is not connected: onWebSocketTaskClosed/onComplete follow
        // and may carry a close code.
        return;
      }
      final code = error.domain == 'NSPOSIXErrorDomain' && error.code == 100
          ? 1002
          : 1006;
      _task.cancel();
      _connectionClosed(code, utf8.encode(error.description));
    } else {
      _task.cancel();
      _connectionClosed(1006, utf8.encode(error.toString()));
    }
  }

  /// The peer sent a close frame (`onWebSocketTaskClosed`).
  @visibleForTesting
  void handlePeerClose(int? closeCode, List<int>? reason) {
    _connectionClosed(closeCode, reason);
  }

  /// The task completed (`onComplete`) after the handshake.
  @visibleForTesting
  void handleTaskComplete() {
    _connectionClosed(1006, utf8.encode('abnormal close'));
  }

  void _connectionClosed(int? closeCode, List<int>? reason) {
    if (_events.isClosed) {
      return;
    }
    // allowMalformed: the close reason is peer-controlled bytes with no UTF-8
    // guarantee. A strict decode would throw out of the delegate callback and
    // skip the CloseReceived event, leaving the sync layer blind to the close
    // until its inactivity timeout. The reason is diagnostic-only.
    final closeReason = reason == null
        ? ''
        : utf8.decode(reason, allowMalformed: true);
    _events
      ..add(CloseReceived(closeCode, closeReason))
      ..close();
  }

  @override
  void sendBytes(Uint8List b) {
    if (_events.isClosed) {
      throw WebSocketConnectionClosed();
    }
    _task.sendBytes(b).then((_) {}, onError: _closeConnectionWithError);
  }

  @override
  void sendText(String s) {
    if (_events.isClosed) {
      throw WebSocketConnectionClosed();
    }
    _task.sendText(s).then((_) {}, onError: _closeConnectionWithError);
  }

  @override
  Future<void> close([int? code, String? reason]) async {
    if (_events.isClosed) {
      throw WebSocketConnectionClosed();
    }

    if (code != null && code != 1000 && !(code >= 3000 && code <= 4999)) {
      throw ArgumentError(
        'Invalid argument: $code, close code must be 1000 or '
        'in the range 3000-4999',
      );
    }
    if (reason != null && utf8.encode(reason).length > 123) {
      throw ArgumentError.value(
        reason,
        'reason',
        'reason must be <= 123 bytes long when encoded as UTF-8',
      );
    }

    unawaited(_events.close());
    if (code != null) {
      _task.cancelWithCloseCode(code, utf8.encode(reason ?? ''));
    } else {
      _task.cancel();
    }
  }

  @override
  Stream<WebSocketEvent> get events => _events.stream;

  @override
  String get protocol => _protocol;
}

/// [CupertinoSocketTask] backed by a real NSURLSessionWebSocketTask.
class _UrlSessionSocketTask implements CupertinoSocketTask {
  _UrlSessionSocketTask(this._task);

  final URLSessionWebSocketTask _task;

  @override
  Future<WebSocketEvent> receive() async {
    final URLSessionWebSocketMessage message;
    try {
      message = await _task.receiveMessage();
    } on objc.NSError catch (error) {
      throw CupertinoTaskError.fromNSError(error);
    }
    switch (message.type) {
      case NSURLSessionWebSocketMessageType
          .NSURLSessionWebSocketMessageTypeString:
        return TextDataReceived(message.string!);
      case NSURLSessionWebSocketMessageType
          .NSURLSessionWebSocketMessageTypeData:
        return BinaryDataReceived(Uint8List.fromList(message.data!.toList()));
    }
  }

  @override
  Future<void> sendText(String text) =>
      _send(URLSessionWebSocketMessage.fromString(text));

  @override
  Future<void> sendBytes(Uint8List bytes) =>
      _send(URLSessionWebSocketMessage.fromData(bytes.toNSData()));

  Future<void> _send(URLSessionWebSocketMessage message) async {
    try {
      await _task.sendMessage(message);
    } on objc.NSError catch (error) {
      throw CupertinoTaskError.fromNSError(error);
    }
  }

  @override
  void cancel() => _task.cancel();

  @override
  void cancelWithCloseCode(int code, Uint8List reason) =>
      _task.cancelWithCloseCode(code, reason.toNSData());
}
