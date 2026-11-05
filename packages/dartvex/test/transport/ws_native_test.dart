import 'dart:async';
import 'dart:io';

import 'package:dartvex/src/transport/ws_interface.dart';
import 'package:dartvex/src/transport/ws_native.dart';
import 'package:test/test.dart';

void main() {
  group('NativeWebSocketAdapter', () {
    test(
        'a binary frame with malformed UTF-8 surfaces as a replacement '
        'string instead of an uncaught zone error', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        // 0xC3 opens a two-byte sequence; 0x28 is not a continuation byte.
        socket.add(<int>[0xC3, 0x28, 0xFF]);
      });

      final adapter = NativeWebSocketAdapter(clientId: 'test-client');
      addTearDown(adapter.close);
      final received = <String>[];
      final errors = <Object>[];
      await runZonedGuarded(() async {
        adapter.messages.listen(received.add);
        await adapter.connect('ws://127.0.0.1:${server.port}');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }, (error, stackTrace) {
        errors.add(error);
      });

      expect(
        errors,
        isEmpty,
        reason: 'malformed network input must never escape the adapter as an '
            'uncaught zone error — that kills the isolate in a pure-Dart app',
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

    // Contract tests against a loopback server (F178).
    Future<_LoopbackServer> startServer() async {
      final server = await _LoopbackServer.start();
      addTearDown(server.close);
      return server;
    }

    test('connects, sends, receives, and sends the Convex-Client header',
        () async {
      final server = await startServer();
      final adapter = NativeWebSocketAdapter(clientId: 'test-client');
      addTearDown(adapter.close);
      final received = <String>[];
      adapter.messages.listen(received.add);

      await adapter.connect(server.url);
      expect(adapter.isConnected, isTrue);
      final serverSocket = await server.nextSocket;
      expect(server.clientHeaders.single, 'test-client');

      adapter.send('ping');
      expect(await server.nextMessage, 'ping');
      serverSocket.add('pong');
      await _until(() => received.isNotEmpty);
      expect(received, <String>['pong']);
    });

    test('isConnected is false by the time a close event is delivered',
        () async {
      final server = await startServer();
      final adapter = NativeWebSocketAdapter(clientId: 'test-client');
      addTearDown(adapter.close);
      final observedWhileClosing = <bool>[];
      final events = <WebSocketCloseEvent>[];
      adapter.closeEvents.listen((event) {
        observedWhileClosing.add(adapter.isConnected);
        events.add(event);
      });

      await adapter.connect(server.url);
      final serverSocket = await server.nextSocket;
      await serverSocket.close(4000, 'SubscriptionsWorkerFullError');
      await _until(() => events.isNotEmpty);

      expect(observedWhileClosing, <bool>[false]);
      expect(events.single.code, 4000);
      expect(events.single.reason, 'SubscriptionsWorkerFullError');
    });

    test('close() emits a close event and detaches the socket immediately',
        () async {
      final server = await startServer();
      final adapter = NativeWebSocketAdapter(clientId: 'test-client');
      final events = <WebSocketCloseEvent>[];
      adapter.closeEvents.listen(events.add);

      await adapter.connect(server.url);
      final closeFuture = adapter.close();
      expect(adapter.isConnected, isFalse);
      expect(() => adapter.send('late'), throwsStateError);
      await closeFuture;
      await _until(() => events.isNotEmpty);
      expect(events, hasLength(1));
    });

    test('a close() that races connect discards the late socket', () async {
      final server = await startServer();
      server.upgradeDelay = const Duration(milliseconds: 100);
      final adapter = NativeWebSocketAdapter(clientId: 'test-client');
      addTearDown(adapter.close);

      final connectFuture = adapter.connect(server.url);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await adapter.close();
      // connect() returns normally but leaves no open socket behind; the sync
      // layer treats that as a failed attempt.
      await connectFuture;
      expect(adapter.isConnected, isFalse);
      final serverSocket = await server.nextSocket;
      await _until(() => serverSocket.closeCode != null);
    });

    test('frames from a superseded socket are not delivered', () async {
      final server = await startServer();
      final adapter = NativeWebSocketAdapter(clientId: 'test-client');
      addTearDown(adapter.close);
      final received = <String>[];
      adapter.messages.listen(received.add);

      await adapter.connect(server.url);
      final first = await server.nextSocket;
      await adapter.connect(server.url);
      final second = await server.nextSocket;

      // The first socket is closing; anything it still sends must not leak.
      first.add('stale');
      second.add('fresh');
      await _until(() => received.contains('fresh'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(received, <String>['fresh']);
    });
  });
}

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > timeout) {
      fail('Timed out waiting for condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _LoopbackServer {
  _LoopbackServer._(this._server) {
    _server.listen((request) async {
      clientHeaders.add(request.headers.value('Convex-Client'));
      final delay = upgradeDelay;
      if (delay != null) {
        await Future<void>.delayed(delay);
      }
      final socket = await WebSocketTransformer.upgrade(request);
      _sockets.add(socket);
      socket.listen(
        (dynamic data) => _messages.add(data as String),
        onError: (_) {},
      );
    });
  }

  static Future<_LoopbackServer> start() async {
    return _LoopbackServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
  }

  final HttpServer _server;
  final StreamController<WebSocket> _sockets = StreamController<WebSocket>();
  final StreamController<String> _messages = StreamController<String>();
  late final StreamIterator<WebSocket> _socketIterator =
      StreamIterator<WebSocket>(_sockets.stream);
  late final StreamIterator<String> _messageIterator =
      StreamIterator<String>(_messages.stream);
  final List<String?> clientHeaders = <String?>[];
  Duration? upgradeDelay;

  String get url => 'ws://127.0.0.1:${_server.port}';

  Future<WebSocket> get nextSocket async {
    if (!await _socketIterator.moveNext()) {
      throw StateError('server closed');
    }
    return _socketIterator.current;
  }

  Future<String> get nextMessage async {
    if (!await _messageIterator.moveNext()) {
      throw StateError('server closed');
    }
    return _messageIterator.current;
  }

  Future<void> close() => _server.close(force: true);
}
