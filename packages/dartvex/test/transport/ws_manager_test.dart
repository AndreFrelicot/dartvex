import 'dart:async';
import 'dart:convert';

import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/logging.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:dartvex/src/transport/ws_interface.dart';
import 'package:dartvex/src/transport/ws_manager.dart';
import 'package:test/test.dart';

import '../test_helpers/mock_web_socket_adapter.dart';

void main() {
  group('WebSocketManager', () {
    test('sends connect only after adapter connect completes', () async {
      final adapter = MockWebSocketAdapter();
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();

      expect(adapter.connectedUrls.single, endsWith('/api/0.1.0/sync'));
      expect(adapter.decodedSentMessages.single['type'], 'Connect');

      await manager.dispose();
    });

    test('sendMessages reports no sent messages while disconnected', () async {
      final adapter = MockWebSocketAdapter();
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      final sentMessages = await manager.sendMessages(
        const <ClientMessage>[
          Mutation(
            requestId: 1,
            udfPath: 'messages:send',
            args: <dynamic>[
              <String, dynamic>{'body': 'hello'}
            ],
          ),
        ],
      );

      expect(sentMessages, isEmpty);
      expect(adapter.sentMessages, isEmpty);

      await manager.dispose();
    });

    test('sendMessages reports sent prefix when adapter send throws', () async {
      final adapter = _ThrowingSendAdapter(failAtSentCount: 1);
      final sentCallbacks = <List<ClientMessage>>[];
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onMessagesSent: sentCallbacks.add,
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );
      await adapter.connect('wss://demo.convex.cloud/api/0.1.0/sync');

      final first = const Mutation(
        requestId: 1,
        udfPath: 'messages:send',
        args: <dynamic>[
          <String, dynamic>{'body': 'first'}
        ],
      );
      final second = const Mutation(
        requestId: 2,
        udfPath: 'messages:send',
        args: <dynamic>[
          <String, dynamic>{'body': 'second'}
        ],
      );
      final sentMessages = await manager.sendMessages(<ClientMessage>[
        first,
        second,
      ]);

      expect(sentMessages, <ClientMessage>[first]);
      expect(sentCallbacks.single, <ClientMessage>[first]);
      expect(adapter.decodedSentMessages.single['requestId'], 1);
      expect(adapter.isConnected, isFalse);

      await manager.dispose();
    });

    test('reconnect reuses session ID and increments connection count',
        () async {
      final adapter = MockWebSocketAdapter();
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      adapter.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final connectMessages = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Connect')
          .toList(growable: false);

      expect(connectMessages, hasLength(2));
      expect(connectMessages.first['connectionCount'], 0);
      expect(connectMessages.last['connectionCount'], 1);
      expect(
        connectMessages.last['sessionId'],
        connectMessages.first['sessionId'],
      );

      await manager.dispose();
    });

    test('propagates close metadata into reconnect diagnostics', () async {
      final adapter = MockWebSocketAdapter();
      final events = <DartvexLogEvent>[];
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
        logLevel: DartvexLogLevel.info,
        logger: events.add,
      );

      await manager.start();
      adapter.disconnect(
        code: 4001,
        reason: 'InternalServerError: deployment push',
        wasClean: false,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final connectMessages = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Connect')
          .toList(growable: false);
      expect(connectMessages, hasLength(2));
      expect(
        connectMessages.last['lastCloseReason'],
        'InternalServerError: deployment push',
      );

      final closeLog =
          events.singleWhere((event) => event.message == 'WebSocket closed');
      expect(closeLog.data?['reason'], 'InternalServerError: deployment push');
      expect(closeLog.data?['closeReason'],
          'InternalServerError: deployment push');
      expect(closeLog.data?['code'], 4001);
      expect(closeLog.data?['wasClean'], isFalse);

      await manager.dispose();
    });

    test('close code fallback avoids stale reconnect reason', () async {
      final adapter = MockWebSocketAdapter();
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      adapter.disconnect(reason: 'first close');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      adapter.disconnect(code: 1006);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final connectMessages = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Connect')
          .toList(growable: false);
      expect(connectMessages, hasLength(3));
      expect(
        connectMessages.last['lastCloseReason'],
        'WebSocket closed with code 1006',
      );

      await manager.dispose();
    });

    test('handles close event and connect failure once', () async {
      final adapter = _FailingThenConnectingAdapter();
      final disconnectReasons = <String>[];
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (reason) async {
          disconnectReasons.add(reason);
        },
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(adapter.connectAttempts, 2);
      expect(disconnectReasons, <String>['WebSocket closed with code 1006']);
      final connectMessages = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Connect')
          .toList(growable: false);
      expect(connectMessages, hasLength(1));
      expect(connectMessages.single['connectionCount'], 1);
      expect(
        connectMessages.single['lastCloseReason'],
        'WebSocket closed with code 1006',
      );

      await manager.dispose();
    });

    test('reports metrics for direct transitions with timing fields', () async {
      final adapter = MockWebSocketAdapter();
      final metrics = <TransitionMetrics>[];
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
        onTransitionMetrics: metrics.add,
      );

      await manager.start();
      final transition = Transition(
        startVersion: const StateVersion.initial(),
        endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
        modifications: const <StateModification>[
          QueryUpdated(queryId: 1, value: 'hello'),
        ],
        clientClockSkew: 0,
        serverTs:
            (DateTime.now().millisecondsSinceEpoch.toDouble() - 150) * 1000000,
      );
      final raw = jsonEncode(transition.toJson());

      adapter.pushServerMessage(transition.toJson());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(metrics, hasLength(1));
      expect(metrics.single.messageSizeBytes, utf8.encode(raw).length);
      expect(metrics.single.transitTimeMs, greaterThan(0));
      expect(metrics.single.bytesPerSecond, greaterThan(0));

      await manager.dispose();
    });

    test('reassembles transition chunks before handing them off', () async {
      final adapter = MockWebSocketAdapter();
      final received = <ServerMessage>[];
      final metrics = <TransitionMetrics>[];
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (message) {
          received.add(message);
          return const <ClientMessage>[];
        },
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
        onTransitionMetrics: metrics.add,
      );

      await manager.start();
      final transition = Transition(
        startVersion: const StateVersion.initial(),
        endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
        modifications: const <StateModification>[
          QueryUpdated(queryId: 1, value: 'hello'),
        ],
        clientClockSkew: 0,
        serverTs:
            (DateTime.now().millisecondsSinceEpoch.toDouble() - 200) * 1000000,
      );
      final raw = jsonEncode(transition.toJson());
      final midpoint = raw.length ~/ 2;
      final partOne = base64Encode(utf8.encode(raw.substring(0, midpoint)));
      final partTwo = base64Encode(utf8.encode(raw.substring(midpoint)));

      adapter.pushServerMessage(
        TransitionChunk(
          chunk: partOne,
          partNumber: 1,
          totalParts: 2,
          transitionId: 'chunk-1',
        ).toJson(),
      );
      adapter.pushServerMessage(
        TransitionChunk(
          chunk: partTwo,
          partNumber: 2,
          totalParts: 2,
          transitionId: 'chunk-1',
        ).toJson(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(received.single, isA<Transition>());
      expect(metrics, hasLength(1));
      expect(metrics.single.messageSizeBytes, utf8.encode(raw).length);
      expect(metrics.single.transitTimeMs, greaterThan(0));
      await manager.dispose();
    });

    test('TransitionMetrics toString is human-readable', () {
      final metrics = TransitionMetrics(
        transitTimeMs: 150,
        messageSizeBytes: 5000000,
        bytesPerSecond: 33333333,
      );

      expect(metrics.toString(), contains('150ms'));
      expect(metrics.toString(), contains('5.0MB'));
    });
  });
}

class _ThrowingSendAdapter extends MockWebSocketAdapter {
  _ThrowingSendAdapter({required this.failAtSentCount});

  final int failAtSentCount;

  @override
  void send(String message) {
    if (sentMessages.length == failAtSentCount) {
      throw StateError('send failed');
    }
    super.send(message);
  }
}

class _FailingThenConnectingAdapter implements WebSocketAdapter {
  final StreamController<String> _messagesController =
      StreamController<String>.broadcast();
  final StreamController<WebSocketCloseEvent> _closeController =
      StreamController<WebSocketCloseEvent>.broadcast(sync: true);

  final List<String> sentMessages = <String>[];
  final List<String> connectedUrls = <String>[];
  int connectAttempts = 0;
  bool _connected = false;

  @override
  Future<void> connect(String url) async {
    connectedUrls.add(url);
    connectAttempts += 1;
    if (connectAttempts == 1) {
      _closeController.add(const WebSocketCloseEvent(code: 1006));
      throw StateError('connect failed');
    }
    _connected = true;
  }

  @override
  void send(String message) {
    if (!_connected) {
      throw StateError('Mock socket is disconnected');
    }
    sentMessages.add(message);
  }

  List<Map<String, dynamic>> get decodedSentMessages {
    return sentMessages
        .map((message) => jsonDecode(message) as Map<String, dynamic>)
        .toList(growable: false);
  }

  @override
  Stream<String> get messages => _messagesController.stream;

  @override
  Stream<WebSocketCloseEvent> get closeEvents => _closeController.stream;

  @override
  Future<void> close() async {
    if (!_connected) {
      return;
    }
    _connected = false;
    _closeController.add(const WebSocketCloseEvent());
  }

  @override
  bool get isConnected => _connected;
}
