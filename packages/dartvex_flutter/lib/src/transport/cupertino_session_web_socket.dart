// Derived from package:cupertino_http's CupertinoWebSocket
// (https://github.com/dart-lang/http, BSD-3-Clause, Dart project authors),
// with one behavioral addition: this variant OWNS its URLSession and
// invalidates it once the connection ends.
//
// Foundation keeps a URLSession (and its delegate) alive until the session is
// explicitly invalidated; upstream CupertinoWebSocket never invalidates the
// session it creates per connect(), so every connection attempt leaks a
// native session — unacceptable for a sync client that reconnects forever.
// See https://developer.apple.com/documentation/foundation/urlsession/1407428-finishtasksandinvalidate
// and https://github.com/dart-lang/http/issues/1282 for context.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cupertino_http/cupertino_http.dart';
import 'package:objective_c/objective_c.dart' as objc;
import 'package:web_socket/web_socket.dart';

/// A [WebSocket] over NSURLSessionWebSocketTask that owns its [URLSession]
/// and invalidates it when the connection ends, so repeated connect attempts
/// do not leak native sessions.
class OwnedSessionCupertinoWebSocket implements WebSocket {
  /// Opens a WebSocket connection to [url] (`ws`/`wss` only).
  ///
  /// The returned socket owns the [URLSession] created for it; the session is
  /// invalidated when the connection closes, errors, or fails to open.
  static Future<OwnedSessionCupertinoWebSocket> connect(
    Uri url, {
    URLSessionConfiguration? config,
  }) async {
    if (!url.isScheme('ws') && !url.isScheme('wss')) {
      throw ArgumentError.value(
        url,
        'url',
        'only ws: and wss: schemes are supported',
      );
    }

    final readyCompleter = Completer<OwnedSessionCupertinoWebSocket>();
    late OwnedSessionCupertinoWebSocket webSocket;
    late URLSession session;

    session = URLSession.sessionWithConfiguration(
      config ?? URLSessionConfiguration.defaultSessionConfiguration(),
      // In a successful flow, the callbacks are made in this order:
      // onWebSocketTaskOpened(...)        // Good connect.
      // <receive/send messages to the peer>
      // onWebSocketTaskClosed(...)        // Optional: peer sent Close frame.
      // onComplete(..., error=null)       // Disconnected.
      //
      // In a failure to connect to the peer, the flow is:
      // onComplete(session, task, error=error)
      //
      // `onComplete` can also be called at any point if the peer is
      // disconnected without Close frames being exchanged.
      onWebSocketTaskOpened: (session, task, protocol) {
        webSocket = OwnedSessionCupertinoWebSocket._(
          task,
          protocol ?? '',
          session,
        );
        readyCompleter.complete(webSocket);
      },
      onWebSocketTaskClosed: (session, task, closeCode, reason) {
        assert(readyCompleter.isCompleted);
        webSocket._connectionClosed(closeCode, reason);
      },
      onComplete: (session, task, error) {
        if (!readyCompleter.isCompleted) {
          // There was an error creating the connection (or a logic error).
          if (error == null) {
            throw AssertionError(
              'expected an error or "onWebSocketTaskOpened" to be called '
              'first',
            );
          }
          readyCompleter.completeError(
            ConnectionException('connection ended unexpectedly', error),
          );
          // The socket object was never created, so nothing else will
          // release this failed attempt's session.
          session.finishTasksAndInvalidate();
        } else {
          // Either side closed (then `_connectionClosed` is a no-op) or an
          // error occurred (then it surfaces the abnormal close).
          webSocket._connectionClosed(
            1006,
            'abnormal close'.codeUnits.toNSData(),
          );
        }
      },
    );

    session.webSocketTaskWithURL(url, protocols: null).resume();
    return readyCompleter.future;
  }

  final URLSessionWebSocketTask _task;
  final String _protocol;
  final URLSession _session;
  final _events = StreamController<WebSocketEvent>();
  bool _sessionInvalidated = false;

  OwnedSessionCupertinoWebSocket._(this._task, this._protocol, this._session) {
    _scheduleReceive();
  }

  /// Invalidates the owned session exactly once. Until a session is
  /// invalidated, Foundation keeps it (and its delegate) alive.
  void _invalidateSession() {
    if (_sessionInvalidated) {
      return;
    }
    _sessionInvalidated = true;
    _session.finishTasksAndInvalidate();
  }

  /// Handles an incoming message from the peer and schedules receiving the
  /// next one.
  void _handleMessage(URLSessionWebSocketMessage value) {
    if (_events.isClosed) return;

    late WebSocketEvent event;
    switch (value.type) {
      case NSURLSessionWebSocketMessageType
            .NSURLSessionWebSocketMessageTypeString:
        event = TextDataReceived(value.string!);
        break;
      case NSURLSessionWebSocketMessageType
            .NSURLSessionWebSocketMessageTypeData:
        event = BinaryDataReceived(Uint8List.fromList(value.data!.toList()));
        break;
    }
    _events.add(event);
    _scheduleReceive();
  }

  void _scheduleReceive() {
    unawaited(
      _task.receiveMessage().then(
            _handleMessage,
            onError: _closeConnectionWithError,
          ),
    );
  }

  /// Closes the connection due to an error and sends the [CloseReceived]
  /// event.
  void _closeConnectionWithError(Object e) {
    if (e is objc.NSError) {
      final domain = e.domain.toDartString();
      if (domain == 'NSPOSIXErrorDomain' && e.code == 57) {
        // Socket is not connected: onWebSocketTaskClosed/onComplete will be
        // invoked and may carry a close code.
        return;
      }
      final (int code, String reason) = switch ([domain, e.code]) {
        ['NSPOSIXErrorDomain', 100] => (
            1002,
            e.localizedDescription.toDartString(),
          ),
        _ => (1006, e.localizedDescription.toDartString()),
      };
      _task.cancel();
      _connectionClosed(code, reason.codeUnits.toNSData());
    } else {
      throw StateError('unexpected error: $e');
    }
  }

  void _connectionClosed(int? closeCode, objc.NSData? reason) {
    if (!_events.isClosed) {
      // allowMalformed: the close reason is peer-controlled NSData with no
      // UTF-8 guarantee. A strict decode would throw out of the session
      // delegate callback, skipping both the CloseReceived event (leaving the
      // sync layer blind to the close until its inactivity timeout) and the
      // session invalidation below (leaking the native session). The reason
      // is diagnostic-only, so replacement characters are harmless.
      final closeReason = reason == null
          ? ''
          : utf8.decode(reason.toList(), allowMalformed: true);

      _events
        ..add(CloseReceived(closeCode, closeReason))
        ..close();
    }
    _invalidateSession();
  }

  @override
  void sendBytes(Uint8List b) {
    if (_events.isClosed) {
      throw WebSocketConnectionClosed();
    }
    _task
        .sendMessage(URLSessionWebSocketMessage.fromData(b.toNSData()))
        .then((value) => value, onError: _closeConnectionWithError);
  }

  @override
  void sendText(String s) {
    if (_events.isClosed) {
      throw WebSocketConnectionClosed();
    }
    _task
        .sendMessage(URLSessionWebSocketMessage.fromString(s))
        .then((value) => value, onError: _closeConnectionWithError);
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
      _task.cancelWithCloseCode(code, utf8.encode(reason ?? '').toNSData());
    } else {
      _task.cancel();
    }
    _invalidateSession();
  }

  @override
  Stream<WebSocketEvent> get events => _events.stream;

  @override
  String get protocol => _protocol;
}
