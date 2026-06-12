import 'dart:async';
import 'dart:typed_data';

import 'package:dartvex/dartvex.dart';
import 'package:dartvex_flutter/src/transport/cupertino_web_socket_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket/web_socket.dart';

/// In-memory [WebSocket] standing in for CupertinoWebSocket in contract
/// tests. Mirrors its observable behavior: the events stream ends with a
/// [CloseReceived] on remote close, while a local [close] ends the stream
/// silently; sends after close throw [WebSocketConnectionClosed].
class _FakeWebSocket implements WebSocket {
  final StreamController<WebSocketEvent> _events =
      StreamController<WebSocketEvent>();
  final List<String> sentText = <String>[];
  bool closed = false;
  int? closeCode;

  void receiveText(String text) => _events.add(TextDataReceived(text));

  void receiveBinary(List<int> data) =>
      _events.add(BinaryDataReceived(Uint8List.fromList(data)));

  void emitError(Object error) => _events.addError(error);

  void remoteClose(int code, [String reason = '']) {
    _events
      ..add(CloseReceived(code, reason))
      ..close();
  }

  @override
  Stream<WebSocketEvent> get events => _events.stream;

  @override
  void sendText(String s) {
    if (closed) {
      throw WebSocketConnectionClosed();
    }
    sentText.add(s);
  }

  @override
  void sendBytes(_) => throw UnimplementedError();

  @override
  Future<void> close([int? code, String? reason]) async {
    if (closed) {
      throw WebSocketConnectionClosed();
    }
    closed = true;
    closeCode = code;
    await _events.close();
  }

  @override
  String get protocol => '';
}

void main() {
  group('CupertinoWebSocketAdapter contract', () {
    late _FakeWebSocket fake;
    late CupertinoWebSocketAdapter adapter;
    late List<Uri> connectedUrls;
    Future<WebSocket> Function(Uri, String)? connectorOverride;

    setUp(() {
      fake = _FakeWebSocket();
      connectedUrls = <Uri>[];
      connectorOverride = null;
      adapter = CupertinoWebSocketAdapter(
        clientId: 'test-client',
        connector: (url, clientId) {
          connectedUrls.add(url);
          final override = connectorOverride;
          if (override != null) {
            return override(url, clientId);
          }
          return Future<WebSocket>.value(fake);
        },
      );
    });

    test('connect resolves and reports connected', () async {
      await adapter.connect('wss://example.convex.cloud/sync');
      expect(adapter.isConnected, isTrue);
      expect(
          connectedUrls.single.toString(), 'wss://example.convex.cloud/sync');
    });

    test('a failed connect rejects the future and stays disconnected',
        () async {
      connectorOverride =
          (_, __) => Future<WebSocket>.error(StateError('refused'));
      await expectLater(
        adapter.connect('wss://example.convex.cloud/sync'),
        throwsStateError,
      );
      expect(adapter.isConnected, isFalse);
    });

    test('text and binary frames surface on messages', () async {
      await adapter.connect('wss://example.convex.cloud/sync');
      final received = <String>[];
      final sub = adapter.messages.listen(received.add);
      fake.receiveText('{"type":"Ping"}');
      fake.receiveBinary('{"type":"Pong"}'.codeUnits);
      await Future<void>.delayed(Duration.zero);
      expect(received, ['{"type":"Ping"}', '{"type":"Pong"}']);
      await sub.cancel();
    });

    test(
        'a binary frame with malformed UTF-8 surfaces as a replacement '
        'string instead of an uncaught zone error', () async {
      final received = <String>[];
      final errors = <Object>[];
      await runZonedGuarded(() async {
        await adapter.connect('wss://example.convex.cloud/sync');
        adapter.messages.listen(received.add);
        // 0xC3 opens a two-byte sequence; 0x28 is not a continuation byte.
        fake.receiveBinary(<int>[0xC3, 0x28, 0xFF]);
        await Future<void>.delayed(Duration.zero);
      }, (error, stackTrace) {
        errors.add(error);
      });
      expect(
        errors,
        isEmpty,
        reason: 'malformed network input must never escape the adapter as an '
            'uncaught zone error',
      );
      expect(received, hasLength(1));
      expect(
        received.single,
        contains('�'),
        reason: 'malformed bytes decode with replacement characters; the '
            'garbled message then fails JSON parsing upstream, which drives '
            'the InvalidServerMessage reconnect instead of a crash',
      );
    });

    test('a socket event stream error surfaces as a close event', () async {
      final closes = <WebSocketCloseEvent>[];
      final errors = <Object>[];
      await runZonedGuarded(() async {
        await adapter.connect('wss://example.convex.cloud/sync');
        final sub = adapter.closeEvents.listen(closes.add);
        fake.emitError(StateError('stream failed'));
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        await sub.cancel();
      }, (error, stackTrace) {
        errors.add(error);
      });

      expect(
        errors,
        isEmpty,
        reason: 'socket stream errors must reach the sync layer as close '
            'events instead of escaping as uncaught zone errors',
      );
      expect(adapter.isConnected, isFalse);
      expect(fake.closed, isTrue);
      expect(fake.closeCode, 1000);
      expect(closes, hasLength(1));
      expect(closes.single.code, 1006);
      expect(closes.single.errorMessage, contains('stream failed'));
    });

    test('send forwards to the socket; throws StateError when disconnected',
        () async {
      expect(() => adapter.send('x'), throwsStateError);
      await adapter.connect('wss://example.convex.cloud/sync');
      adapter.send('{"type":"Connect"}');
      expect(fake.sentText, ['{"type":"Connect"}']);
    });

    test('send converts a closed-socket race into StateError', () async {
      await adapter.connect('wss://example.convex.cloud/sync');
      fake.closed = true; // Socket died, close event not yet delivered.
      expect(() => adapter.send('x'), throwsStateError);
    });

    test(
        'remote close clears isConnected before delivering the close event '
        'and carries code/reason', () async {
      await adapter.connect('wss://example.convex.cloud/sync');
      final closes = <WebSocketCloseEvent>[];
      bool? connectedAtDelivery;
      final sub = adapter.closeEvents.listen((event) {
        connectedAtDelivery = adapter.isConnected;
        closes.add(event);
      });
      fake.remoteClose(1011, 'InternalServerError');
      await Future<void>.delayed(Duration.zero);
      expect(closes, hasLength(1));
      expect(connectedAtDelivery, isFalse,
          reason: 'adapter contract: isConnected must be false by the time '
              'a close event for the current socket is delivered');
      expect(closes.single.code, 1011);
      expect(closes.single.reason, 'InternalServerError');
      await sub.cancel();
    });

    test(
        'close() closes the socket with a clean 1000 and emits one close '
        'event from the ended stream', () async {
      await adapter.connect('wss://example.convex.cloud/sync');
      final closes = <WebSocketCloseEvent>[];
      final sub = adapter.closeEvents.listen(closes.add);
      await adapter.close();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.isConnected, isFalse);
      expect(fake.closed, isTrue);
      expect(fake.closeCode, 1000);
      expect(closes, hasLength(1));
      await sub.cancel();
    });

    test('frames from a superseded socket never reach messages', () async {
      await adapter.connect('wss://example.convex.cloud/sync');
      final staleSocket = fake;
      final received = <String>[];
      final sub = adapter.messages.listen(received.add);
      // A frame still in flight (queued, undelivered) when a reconnect
      // supersedes its socket must be dropped by the identical() guard.
      staleSocket.receiveText('stale');
      fake = _FakeWebSocket();
      await adapter.connect('wss://example.convex.cloud/sync');
      fake.receiveText('fresh');
      await Future<void>.delayed(Duration.zero);
      expect(received, ['fresh']);
      await sub.cancel();
    });

    test('a connect superseded while in flight discards the late socket',
        () async {
      final lateSocket = _FakeWebSocket();
      final gate = Completer<WebSocket>();
      final connectorStarted = Completer<void>();
      connectorOverride = (_, __) {
        connectorStarted.complete();
        return gate.future;
      };
      final pending = adapter.connect('wss://example.convex.cloud/sync');
      // Wait until the connect is suspended on the platform socket opening —
      // the window where the manager's connect-timeout close() lands.
      await connectorStarted.future;
      await adapter.close();
      gate.complete(lateSocket);
      await pending;
      expect(adapter.isConnected, isFalse);
      expect(lateSocket.closed, isTrue,
          reason: 'late sockets must be closed, not leaked');
    });

    test('reconnect after remote close works and dedupes close events',
        () async {
      await adapter.connect('wss://example.convex.cloud/sync');
      final closes = <WebSocketCloseEvent>[];
      final sub = adapter.closeEvents.listen(closes.add);
      fake.remoteClose(1006);
      await Future<void>.delayed(Duration.zero);
      fake = _FakeWebSocket();
      await adapter.connect('wss://example.convex.cloud/sync');
      expect(adapter.isConnected, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(closes, hasLength(1),
          reason: 'the closed socket must emit exactly one close event');
      await sub.cancel();
    });
  });
}
