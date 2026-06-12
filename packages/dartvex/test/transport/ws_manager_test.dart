import 'dart:async';
import 'dart:convert';
import 'dart:math';

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
    Future<List<Map<String, dynamic>>> waitForConnectMessages(
      MockWebSocketAdapter adapter,
      int expectedCount,
    ) async {
      final stopwatch = Stopwatch()..start();
      while (stopwatch.elapsed < const Duration(seconds: 1)) {
        final messages = adapter.decodedSentMessages
            .where((message) => message['type'] == 'Connect')
            .toList(growable: false);
        if (messages.length >= expectedCount) {
          return messages;
        }
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      fail('Timed out waiting for $expectedCount Connect messages');
    }

    Future<void> waitForConnectAttempts(
      MockWebSocketAdapter adapter,
      int expectedCount,
    ) async {
      final stopwatch = Stopwatch()..start();
      while (stopwatch.elapsed < const Duration(seconds: 1)) {
        if (adapter.connectedUrls.length >= expectedCount) {
          return;
        }
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      fail('Timed out waiting for $expectedCount connect attempts');
    }

    Future<List<DartvexLogEvent>> waitForLogEvents(
      List<DartvexLogEvent> events,
      String message,
      int expectedCount,
    ) async {
      final stopwatch = Stopwatch()..start();
      while (stopwatch.elapsed < const Duration(seconds: 1)) {
        final matching = events
            .where((event) => event.message == message)
            .toList(growable: false);
        if (matching.length >= expectedCount) {
          return matching;
        }
        await pumpEventQueue();
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      fail('Timed out waiting for $expectedCount "$message" log events');
    }

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
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();

      expect(adapter.connectedUrls.single, endsWith('/api/0.1.0/sync'));
      expect(adapter.decodedSentMessages.single['type'], 'Connect');

      await manager.dispose();
    });

    test(
        'pause during an asynchronous connect handshake forces a clean '
        'reconnect instead of dropping the session-restoring messages',
        () async {
      final adapter = MockWebSocketAdapter();
      late WebSocketManager manager;
      var connectedCalls = 0;
      const restore = ModifyQuerySet(
        baseVersion: 0,
        newVersion: 1,
        modifications: <QuerySetOperation>[],
      );
      manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () async {
          connectedCalls += 1;
          if (connectedCalls == 1) {
            // A concurrent auth flow pauses the socket while the handshake
            // messages are still being built.
            manager.pause();
          }
          return const <ClientMessage>[restore];
        },
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => true,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 5));

      // The forced reconnect reopened the socket; the new socket opens paused
      // and defers its handshake, so exactly one Connect frame is on the wire
      // and the session-restoring message was never silently dropped.
      final connectsBeforeResume = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Connect')
          .toList(growable: false);
      expect(connectsBeforeResume, hasLength(1));
      expect(
        adapter.decodedSentMessages
            .where((message) => message['type'] == 'ModifyQuerySet'),
        isEmpty,
      );

      await manager.resume();
      final connects = await waitForConnectMessages(adapter, 2);
      expect(connects, hasLength(2));
      // The deferred handshake replays Connect followed by the restoring
      // query-set message.
      expect(adapter.decodedSentMessages.last['type'], 'ModifyQuerySet');

      await manager.dispose();
    });

    test(
        'ignores a superseded socket close event delivered while a healthy '
        'successor connection is open', () async {
      final adapter = MockWebSocketAdapter();
      final disconnectReasons = <String>[];
      final stateChanges = <(bool, bool)>[];
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (reason) {
          disconnectReasons.add(reason);
        },
        onConnectionStateChanged: (connected, reconnecting) {
          stateChanges.add((connected, reconnecting));
        },
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => true,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      expect(adapter.isConnected, isTrue);
      stateChanges.clear();

      // A previous socket's close timed out on a dead network and was
      // force-destroyed by the platform only after this healthy connection
      // was already established. Its late close event must not tear the
      // healthy connection down.
      adapter.emitStaleCloseEvent(reason: 'ServerInactivity');
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 5));

      expect(disconnectReasons, isEmpty);
      expect(stateChanges, isEmpty);
      expect(adapter.isConnected, isTrue);
      // No reconnect ran: exactly one Connect frame ever hit the wire.
      expect(
        adapter.decodedSentMessages
            .where((message) => message['type'] == 'Connect'),
        hasLength(1),
      );

      await manager.dispose();
    });

    test(
        'a superseded socket close delivered while the successor connect is '
        'in flight does not poison close handling for the new connection',
        () async {
      final adapter = MockWebSocketAdapter();
      final disconnectReasons = <String>[];
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (reason) {
          disconnectReasons.add(reason);
        },
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => true,
        // Index 0 drives the first reconnect immediately; any reconnect a
        // stale close might spuriously schedule lands at index 1 and stays
        // safely outside the test window.
        reconnectBackoff: const <Duration>[
          Duration.zero,
          Duration(seconds: 30),
        ],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      expect(adapter.isConnected, isTrue);

      // The connection drops; the immediate reconnect's adapter.connect() is
      // held in flight by the gate, simulating a slow TCP/TLS handshake.
      final gate = adapter.connectGate = Completer<void>();
      adapter.disconnect(reason: 'NetworkDrop');
      await waitForConnectAttempts(adapter, 2);
      expect(disconnectReasons, ['NetworkDrop']);

      // A previous socket's close, force-destroyed by the platform seconds
      // after its close() timed out, lands while the successor's connect is
      // still in flight. It must not consume the new attempt's close
      // handling.
      adapter.emitStaleCloseEvent(reason: 'ServerInactivity');
      await pumpEventQueue();
      expect(disconnectReasons, ['NetworkDrop']);

      // The in-flight connect completes; the connection is healthy.
      gate.complete();
      adapter.connectGate = null;
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(adapter.isConnected, isTrue);

      // A later real close of the healthy connection must still drive the
      // disconnect bookkeeping (and with it the reconnect schedule); with a
      // poisoned _closeHandled it would be silently ignored, leaving the
      // client disconnected forever.
      adapter.disconnect(reason: 'LaterNetworkDrop');
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(disconnectReasons, ['NetworkDrop', 'LaterNetworkDrop']);

      await manager.dispose();
    });

    test('message stream errors reconnect without escaping the zone', () async {
      final unhandledErrors = <Object>[];
      await runZonedGuarded(() async {
        final adapter = MockWebSocketAdapter();
        final disconnectReasons = <String>[];
        final manager = WebSocketManager(
          adapter: adapter,
          deploymentUrl: 'https://demo.convex.cloud',
          apiVersion: '0.1.0',
          onConnected: () => const <ClientMessage>[],
          onMessage: (_) => const <ClientMessage>[],
          onDisconnected: disconnectReasons.add,
          onConnectionStateChanged: (_, __) {},
          maxObservedTimestamp: () => null,
          hasSyncedPastLastReconnect: () => true,
          reconnectBackoff: const <Duration>[Duration.zero],
          inactivityTimeout: const Duration(seconds: 30),
        );

        await manager.start();
        adapter.emitMessageStreamError(StateError('message stream failed'));
        await waitForConnectAttempts(adapter, 2);

        expect(disconnectReasons, <String>['WebSocketMessageStreamError']);
        await manager.dispose();
      }, (error, stackTrace) {
        unhandledErrors.add(error);
      });

      expect(unhandledErrors, isEmpty);
    });

    test('stream error during connect closes the half-open adapter', () async {
      final adapter = MockWebSocketAdapter();
      adapter.connectGate = Completer<void>();
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => true,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      final start = manager.start();
      await waitForConnectAttempts(adapter, 1);

      adapter.emitMessageStreamError(StateError('message stream failed'));
      await waitForConnectAttempts(adapter, 2);

      expect(adapter.closeCalls, 1);

      adapter.connectGate!.complete();
      await start;
      await manager.dispose();
    });

    test('close stream errors reconnect without escaping the zone', () async {
      final unhandledErrors = <Object>[];
      await runZonedGuarded(() async {
        final adapter = MockWebSocketAdapter();
        final disconnectReasons = <String>[];
        final manager = WebSocketManager(
          adapter: adapter,
          deploymentUrl: 'https://demo.convex.cloud',
          apiVersion: '0.1.0',
          onConnected: () => const <ClientMessage>[],
          onMessage: (_) => const <ClientMessage>[],
          onDisconnected: disconnectReasons.add,
          onConnectionStateChanged: (_, __) {},
          maxObservedTimestamp: () => null,
          hasSyncedPastLastReconnect: () => true,
          reconnectBackoff: const <Duration>[Duration.zero],
          inactivityTimeout: const Duration(seconds: 30),
        );

        await manager.start();
        adapter.emitCloseStreamError(StateError('close stream failed'));
        await waitForConnectAttempts(adapter, 2);

        expect(disconnectReasons, <String>['WebSocketCloseStreamError']);
        await manager.dispose();
      }, (error, stackTrace) {
        unhandledErrors.add(error);
      });

      expect(unhandledErrors, isEmpty);
    });

    test('dispose ignores adapter close failures', () async {
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
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      adapter.throwOnClose = true;

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
        hasSyncedPastLastReconnect: () => false,
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
        hasSyncedPastLastReconnect: () => false,
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

    test('send failure after adapter disconnect reports disconnect bookkeeping',
        () async {
      final adapter = _DisconnectingThrowingSendAdapter(failAtSentCount: 1);
      final disconnectReasons = <String>[];
      final states = <({bool connected, bool connecting})>[];
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://example.com',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (reason) async {
          disconnectReasons.add(reason);
        },
        onConnectionStateChanged: (connected, connecting) {
          states.add((connected: connected, connecting: connecting));
        },
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
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
      await _waitForConnectMessages(adapter, 2);

      expect(sentMessages, isEmpty);
      expect(disconnectReasons, <String>['FailedToSendMessage']);
      expect(
        states.where((state) => !state.connected && !state.connecting),
        hasLength(1),
      );

      await manager.dispose();
    });

    test('send failure still reconnects when closing the socket throws',
        () async {
      final adapter = _OnceThrowingSendAdapter(failAtSentCount: 2)
        ..throwOnClose = true;
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
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
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
      final connectMessages = await _waitForConnectMessages(adapter, 2);

      expect(sentMessages, <ClientMessage>[first]);
      expect(disconnectReasons, <String>['FailedToSendMessage']);
      expect(connectMessages, hasLength(2));

      adapter.throwOnClose = false;
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
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      adapter.disconnect();

      final connectMessages = await _waitForConnectMessages(adapter, 2);

      expect(connectMessages, hasLength(2));
      expect(connectMessages.first['connectionCount'], 0);
      expect(connectMessages.last['connectionCount'], 1);
      expect(
        connectMessages.last['sessionId'],
        connectMessages.first['sessionId'],
      );

      await manager.dispose();
    });

    test('exposes hasEverConnected, connectionCount, and connectionRetries',
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
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[],
        initialBackoff: Duration.zero,
        backoffJitter: 0,
        inactivityTimeout: const Duration(seconds: 30),
      );

      expect(manager.hasEverConnected, isFalse);
      expect(manager.connectionCount, 0);
      expect(manager.connectionRetries, 0);

      await manager.start();
      expect(manager.hasEverConnected, isTrue);
      expect(manager.connectionCount, 1);

      // A disconnect reconnects (zero backoff): the count tracks successful
      // opens, and the retry index climbs because the client never re-syncs
      // here.
      adapter.disconnect();
      await _waitForConnectMessages(adapter, 2);
      expect(manager.connectionCount, 2);
      expect(manager.connectionRetries, 1);
      expect(manager.hasEverConnected, isTrue);

      await manager.dispose();
    });

    test('increments connectionCount before publishing connected state',
        () async {
      final adapter = MockWebSocketAdapter();
      final countsAtConnected = <int>[];
      late final WebSocketManager manager;
      manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (connected, _) {
          if (connected) {
            countsAtConnected.add(manager.connectionCount);
          }
        },
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[],
        initialBackoff: Duration.zero,
        backoffJitter: 0,
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();

      expect(countsAtConnected, <int>[1]);

      await manager.dispose();
    });

    test('connectionRetries resets once synced past the last reconnect',
        () async {
      final adapter = MockWebSocketAdapter();
      var synced = false;
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => synced,
        reconnectBackoff: const <Duration>[],
        initialBackoff: Duration.zero,
        backoffJitter: 0,
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      adapter.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(manager.connectionRetries, 1);

      // Once the client reports it has caught up, the next handled message
      // resets the retry counter.
      synced = true;
      adapter.pushServerMessage(
        const ActionResponse(requestId: 0, success: true, result: 'ok')
            .toJson(),
      );
      await Future<void>.delayed(Duration.zero);
      expect(manager.connectionRetries, 0);

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
        hasSyncedPastLastReconnect: () => false,
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
      final connectMessages = await waitForConnectMessages(adapter, 2);
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
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      adapter.disconnect(reason: 'first close');
      await waitForConnectMessages(adapter, 2);
      adapter.disconnect(code: 1006);
      final connectMessages = await waitForConnectMessages(adapter, 3);

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
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(adapter.connectAttempts, 2);
      // The close event surfaced while the connect was still in flight, so it
      // is ignored as potentially stale; the failed connect future drives the
      // one disconnect instead, carrying the connect error as the reason.
      expect(disconnectReasons, <String>['Bad state: connect failed']);
      final connectMessages = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Connect')
          .toList(growable: false);
      expect(connectMessages, hasLength(1));
      expect(connectMessages.single['connectionCount'], 0);
      expect(
        connectMessages.single['lastCloseReason'],
        'Bad state: connect failed',
      );

      await manager.dispose();
    });

    test('reconnectNow still reconnects when closing the socket throws',
        () async {
      final adapter = MockWebSocketAdapter()..throwOnClose = true;
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
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      await manager.reconnectNow('AppResumed');
      final connectMessages = await _waitForConnectMessages(adapter, 2);

      expect(disconnectReasons, <String>['AppResumed']);
      expect(connectMessages, hasLength(2));
      expect(connectMessages.last['lastCloseReason'], 'AppResumed');

      adapter.throwOnClose = false;
      await manager.dispose();
    });

    test('reconnectNow during connect does not suppress failed-connect retry',
        () async {
      final adapter = _DelayedFailingThenConnectingAdapter();
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
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      final startFuture = manager.start();
      await Future<void>.delayed(Duration.zero);
      await manager.reconnectNow('AppResumed');
      adapter.failFirstConnect();
      await startFuture;
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(adapter.connectAttempts, 2);
      expect(disconnectReasons, <String>['AppResumed']);
      final connectMessages = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Connect')
          .toList(growable: false);
      expect(connectMessages, hasLength(1));
      expect(connectMessages.single['lastCloseReason'], 'AppResumed');

      await manager.dispose();
    });

    test('reconnectNow during successful connect does not leak close reason',
        () async {
      final adapter = _DelayedConnectingAdapter();
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
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration(hours: 1)],
        inactivityTimeout: const Duration(seconds: 30),
      );

      final startFuture = manager.start();
      await Future<void>.delayed(Duration.zero);
      await manager.reconnectNow('AppResumed');
      adapter.completeConnect();
      await startFuture;

      final connectMessages = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Connect')
          .toList(growable: false);
      expect(connectMessages, hasLength(1));
      expect(connectMessages.single['lastCloseReason'], 'AppResumed');

      adapter.disconnect(code: 1006);
      await Future<void>.delayed(Duration.zero);

      expect(disconnectReasons, <String>['WebSocket closed with code 1006']);

      await manager.dispose();
    });

    test('reconnectNow while silently disconnected reports disconnect',
        () async {
      final adapter = _SilentDisconnectAdapter();
      final disconnectReasons = <String>[];
      final states = <({bool connected, bool connecting})>[];
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://example.com',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (reason) async {
          disconnectReasons.add(reason);
        },
        onConnectionStateChanged: (connected, connecting) {
          states.add((connected: connected, connecting: connecting));
        },
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      adapter.silentlyDisconnect();
      await manager.reconnectNow('ManualReconnect');
      await _waitForConnectMessages(adapter, 2);

      expect(disconnectReasons, <String>['ManualReconnect']);
      expect(
        states.where((state) => !state.connected && !state.connecting),
        hasLength(1),
      );

      await manager.dispose();
    });

    test('connect watchdog times out a hanging connect and retries', () async {
      final adapter = _HangingThenConnectingAdapter();
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
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
        connectTimeout: const Duration(milliseconds: 50),
      );

      await manager.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(adapter.connectAttempts, 2);
      expect(disconnectReasons.single, startsWith('ConnectTimeout'));
      final connectMessages = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Connect')
          .toList(growable: false);
      expect(connectMessages, hasLength(1));

      await manager.dispose();
    });

    test('exponential backoff applies jitter and reason classification',
        () async {
      Future<int> firstScheduledDelay({String? disconnectReason}) async {
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
          hasSyncedPastLastReconnect: () => false,
          reconnectBackoff: const <Duration>[],
          inactivityTimeout: const Duration(seconds: 30),
          initialBackoff: const Duration(seconds: 1),
          maxBackoff: const Duration(seconds: 16),
          backoffJitter: 0.5,
          random: Random(7),
          logLevel: DartvexLogLevel.info,
          logger: events.add,
        );

        await manager.start();
        adapter.disconnect(reason: disconnectReason);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final scheduled =
            events.lastWhere((event) => event.message == 'Reconnect scheduled');
        await manager.dispose();
        return scheduled.data!['delayMs'] as int;
      }

      // Unknown reason -> base 1000ms, retry 0 -> jittered within [500, 1500].
      expect(await firstScheduledDelay(), inInclusiveRange(500, 1500));
      // Overload reason -> base 3000ms, retry 0 -> jittered within [1500, 4500].
      expect(
        await firstScheduledDelay(disconnectReason: 'CommitterFullError'),
        inInclusiveRange(1500, 4500),
      );
    });

    test('reconnectImmediatelyIfWaiting shortcuts the backoff wait', () async {
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
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration(hours: 1)],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      // No-op while connected.
      manager.reconnectImmediatelyIfWaiting();
      expect(adapter.connectedUrls, hasLength(1));

      adapter.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      // Now parked on a 1h backoff timer; a connectivity restore shortcuts it.
      manager.reconnectImmediatelyIfWaiting();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(adapter.connectedUrls, hasLength(2));
      final connectMessages = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Connect')
          .toList(growable: false);
      expect(connectMessages, hasLength(2));

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
        hasSyncedPastLastReconnect: () => false,
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
        hasSyncedPastLastReconnect: () => false,
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
      final partOne = raw.substring(0, midpoint);
      final partTwo = raw.substring(midpoint);

      adapter.pushServerMessage(
        TransitionChunk(
          chunk: partOne,
          partNumber: 0,
          totalParts: 2,
          transitionId: 'chunk-1',
        ).toJson(),
      );
      adapter.pushServerMessage(
        TransitionChunk(
          chunk: partTwo,
          partNumber: 1,
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

    test(
        'invalid transition chunks close and reconnect instead of leaking async',
        () async {
      final adapter = MockWebSocketAdapter();
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
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      adapter.pushServerMessage(
        const TransitionChunk(
          chunk: '{}',
          partNumber: 1,
          totalParts: 2,
          transitionId: 'chunk-1',
        ).toJson(),
      );
      final connectMessages = await _waitForConnectMessages(adapter, 2);

      expect(disconnectReasons, contains('InvalidServerMessage'));
      expect(connectMessages, hasLength(2));

      await manager.dispose();
    });

    test('invalid message still reconnects when closing the socket throws',
        () async {
      final adapter = MockWebSocketAdapter()..throwOnClose = true;
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
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      adapter.pushServerMessage(
        const TransitionChunk(
          chunk: '{}',
          partNumber: 1,
          totalParts: 2,
          transitionId: 'chunk-1',
        ).toJson(),
      );
      final connectMessages = await _waitForConnectMessages(adapter, 2);

      expect(disconnectReasons, <String>['InvalidServerMessage']);
      expect(connectMessages, hasLength(2));

      adapter.throwOnClose = false;
      await manager.dispose();
    });

    test('invalid message after silent disconnect reports disconnect',
        () async {
      final adapter = _SilentDisconnectAdapter();
      final disconnectReasons = <String>[];
      final states = <({bool connected, bool connecting})>[];
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://example.com',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (reason) async {
          disconnectReasons.add(reason);
        },
        onConnectionStateChanged: (connected, connecting) {
          states.add((connected: connected, connecting: connecting));
        },
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      adapter.silentlyDisconnect();
      adapter.pushServerMessage(<String, dynamic>{'type': 'Bogus'});
      await _waitForConnectMessages(adapter, 2);

      expect(disconnectReasons, <String>['InvalidServerMessage']);
      expect(
        states.where((state) => !state.connected && !state.connecting),
        hasLength(1),
      );

      await manager.dispose();
    });

    test('fatal errors do not reset reconnect backoff', () async {
      final adapter = MockWebSocketAdapter();
      final events = <DartvexLogEvent>[];
      late final WebSocketManager manager;
      manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (message) async {
          if (message is FatalError) {
            await manager.reconnectNow(message.error);
          }
          return const <ClientMessage>[];
        },
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[
          Duration(milliseconds: 10),
          Duration(milliseconds: 20),
        ],
        inactivityTimeout: const Duration(seconds: 30),
        logLevel: DartvexLogLevel.info,
        logger: events.add,
      );

      await manager.start();
      adapter.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 15));

      adapter.pushServerMessage(const FatalError(error: 'fatal').toJson());
      await Future<void>.delayed(Duration.zero);

      final schedules = events
          .where((event) => event.message == 'Reconnect scheduled')
          .toList(growable: false);
      expect(schedules.last.data?['delayMs'], 20);

      await manager.dispose();
    });

    test('reconnect backoff resets only after syncing past the last reconnect',
        () async {
      final adapter = MockWebSocketAdapter();
      final events = <DartvexLogEvent>[];
      var synced = false;
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => synced,
        reconnectBackoff: const <Duration>[
          Duration(milliseconds: 10),
          Duration(milliseconds: 20),
          Duration(milliseconds: 40),
        ],
        inactivityTimeout: const Duration(seconds: 30),
        logLevel: DartvexLogLevel.info,
        logger: events.add,
      );

      List<int> scheduledDelays() => events
          .where((event) => event.message == 'Reconnect scheduled')
          .map((event) => event.data!['delayMs'] as int)
          .toList(growable: false);

      Future<void> deliverMessage() async {
        adapter.pushServerMessage(
          const ActionResponse(requestId: 0, success: true, result: 'ok')
              .toJson(),
        );
        await Future<void>.delayed(Duration.zero);
      }

      await manager.start();

      // Flap before re-syncing: a delivered message must not reset the backoff,
      // so the schedule keeps climbing (10ms then 20ms).
      adapter.disconnect();
      await waitForConnectMessages(adapter, 2);
      await deliverMessage();
      adapter.disconnect();
      await waitForLogEvents(events, 'Reconnect scheduled', 2);
      await waitForConnectMessages(adapter, 3);

      expect(scheduledDelays(), <int>[10, 20]);

      // Once the client reports it has re-synced, the next handled message
      // resets the backoff, so the following disconnect schedules from 10ms.
      synced = true;
      await deliverMessage();
      adapter.disconnect();
      await waitForLogEvents(events, 'Reconnect scheduled', 3);

      expect(scheduledDelays(), <int>[10, 20, 10]);

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

    test('a socket opened while paused defers its handshake until resume',
        () async {
      final adapter = MockWebSocketAdapter();
      var connectedCalls = 0;
      final stateChanges = <String>[];
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () {
          connectedCalls += 1;
          return const <ClientMessage>[];
        },
        onResume: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (connected, reconnecting) =>
            stateChanges.add('c=$connected,r=$reconnecting'),
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      manager.pause();
      await manager.start();

      // Connected but paused: no Connect sent, no "connected" state.
      expect(adapter.sentMessages, isEmpty);
      expect(connectedCalls, 0);
      expect(stateChanges, <String>['c=false,r=true']);

      await manager.resume();

      expect(adapter.decodedSentMessages.first['type'], 'Connect');
      expect(connectedCalls, 1);
      expect(stateChanges, <String>['c=false,r=true', 'c=true,r=false']);

      await manager.dispose();
    });

    test('deferred handshake does not send after paused socket closes',
        () async {
      final adapter = MockWebSocketAdapter();
      var connectedCalls = 0;
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'http://localhost:3210',
        apiVersion: '0.1.0',
        onConnected: () {
          connectedCalls += 1;
          return const <ClientMessage>[];
        },
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      manager.pause();
      await manager.start();
      adapter.disconnect(errorMessage: 'network dropped during auth');

      await expectLater(manager.resume(), completes);

      expect(adapter.sentMessages, isEmpty);
      expect(connectedCalls, 0);

      await manager.dispose();
    });

    test(
        'a reconnect after a paused socket closes still defers its handshake '
        'until resume', () async {
      final adapter = MockWebSocketAdapter();
      var connectedCalls = 0;
      final stateChanges = <String>[];
      const restore = ModifyQuerySet(
        baseVersion: 0,
        newVersion: 1,
        modifications: <QuerySetOperation>[],
      );
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () {
          connectedCalls += 1;
          return const <ClientMessage>[restore];
        },
        onResume: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (connected, reconnecting) =>
            stateChanges.add('c=$connected,r=$reconnecting'),
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      manager.pause();
      await manager.start();
      expect(adapter.sentMessages, isEmpty);

      // The paused socket (handshake deferred) dies and the reconnect lands
      // before the pause owner resumes — e.g. a network blip during the
      // initial auth token fetch.
      adapter.disconnect(errorMessage: 'network dropped during auth');
      await waitForConnectAttempts(adapter, 2);
      await pumpEventQueue();

      // The new socket must defer its handshake exactly like the first one:
      // no Connect frame on the wire, no session-restoring messages swallowed
      // by the paused transport, and no premature connected state.
      expect(adapter.isConnected, isTrue);
      expect(adapter.sentMessages, isEmpty);
      expect(connectedCalls, 0);
      expect(stateChanges, isNot(contains('c=true,r=false')));

      await manager.resume();

      // Resume runs the deferred handshake once: a single Connect frame
      // followed by the session-restoring messages.
      final types = adapter.decodedSentMessages
          .map((message) => message['type'])
          .toList(growable: false);
      expect(types, <String>['Connect', 'ModifyQuerySet']);
      expect(connectedCalls, 1);
      expect(stateChanges.last, 'c=true,r=false');

      await manager.dispose();
    });

    test('pause buffers sends and resume flushes buffered messages', () async {
      final adapter = MockWebSocketAdapter();
      const buffered = <ClientMessage>[
        Authenticate(tokenType: 'User', baseVersion: 0, value: 'tok'),
      ];
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onResume: () => buffered,
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      final sentBeforePause = adapter.sentMessages.length;

      manager.pause();
      final blocked = await manager.sendMessages(const <ClientMessage>[
        Mutation(
          requestId: 1,
          udfPath: 'messages:send',
          args: <dynamic>[<String, dynamic>{}],
        ),
      ]);
      expect(blocked, isEmpty);
      expect(adapter.sentMessages.length, sentBeforePause);

      await manager.resume();
      expect(adapter.decodedSentMessages.last['type'], 'Authenticate');

      await manager.dispose();
    });

    test(
        'pause during an asynchronous resume forces a clean reconnect '
        'instead of dropping the resumed messages', () async {
      final adapter = MockWebSocketAdapter();
      late WebSocketManager manager;
      var resumeCalls = 0;
      const restore = ModifyQuerySet(
        baseVersion: 0,
        newVersion: 1,
        modifications: <QuerySetOperation>[],
      );
      manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[restore],
        onResume: () async {
          resumeCalls += 1;
          // A concurrent auth flow pauses the socket while the resumed
          // messages are still being built; sending them now would drop them.
          manager.pause();
          return const <ClientMessage>[
            Authenticate(tokenType: 'User', baseVersion: 0, value: 'tok'),
          ];
        },
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => true,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      final connectsBeforePause = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Connect')
          .length;
      expect(connectsBeforePause, 1);

      manager.pause();
      await manager.resume();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 5));

      // The repause forced a clean reconnect: the Authenticate built by the
      // interrupted resume was never written to the wire, and the fresh
      // socket opened paused with its handshake deferred to the new owner.
      expect(resumeCalls, 1);
      expect(
        adapter.decodedSentMessages
            .where((message) => message['type'] == 'Authenticate'),
        isEmpty,
      );
      expect(
        adapter.decodedSentMessages
            .where((message) => message['type'] == 'Connect'),
        hasLength(1),
      );

      // The new pause owner resumes: the deferred handshake replays Connect
      // and rebuilds the session from onConnected, so nothing was lost.
      await manager.resume();
      final connects = await waitForConnectMessages(adapter, 2);
      expect(connects, hasLength(2));
      expect(adapter.decodedSentMessages.last['type'], 'ModifyQuerySet');

      await manager.dispose();
    });

    test('stop closes without reconnecting and restart re-establishes it',
        () async {
      final adapter = MockWebSocketAdapter();
      var connectedCalls = 0;
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () {
          connectedCalls += 1;
          return const <ClientMessage>[];
        },
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      expect(connectedCalls, 1);
      expect(adapter.isConnected, isTrue);

      await manager.stop();
      expect(adapter.isConnected, isFalse);
      // A scheduled reconnect (backoff 0) would fire here if stop misbehaved.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(connectedCalls, 1);
      expect(adapter.isConnected, isFalse);

      await manager.restart();
      expect(adapter.isConnected, isTrue);
      expect(connectedCalls, 2);

      await manager.dispose();
    });

    test('stop still allows restart when closing the socket throws', () async {
      final adapter = MockWebSocketAdapter();
      var connectedCalls = 0;
      final manager = WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () {
          connectedCalls += 1;
          return const <ClientMessage>[];
        },
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[Duration.zero],
        inactivityTimeout: const Duration(seconds: 30),
      );

      await manager.start();
      expect(connectedCalls, 1);
      expect(adapter.isConnected, isTrue);

      adapter.throwOnClose = true;
      await manager.stop();

      // A failing close must not leave the manager unable to restart after the
      // auth flow finishes. The adapter can still report connected until the
      // next connect replaces the socket, but the manager should be stopped.
      adapter.throwOnClose = false;
      await manager.restart();

      expect(connectedCalls, 2);
      final connectMessages = await _waitForConnectMessages(adapter, 2);
      expect(connectMessages, hasLength(2));

      await manager.dispose();
    });

    // NF1: a client-initiated reconnect (reconnectNow, a detected protocol
    // error, an inactivity timeout) must back off from the official 100ms
    // client base, while an unexpected server/network close uses the
    // reason-classified (overload table / 1s) base. Exercised in exponential
    // mode (empty reconnectBackoff) with jitter disabled for determinism; the
    // production default uses exponential mode, so the fixed-schedule tests
    // elsewhere never cover this.
    WebSocketManager buildExponentialManager(
      MockWebSocketAdapter adapter,
      List<DartvexLogEvent> events,
    ) {
      return WebSocketManager(
        adapter: adapter,
        deploymentUrl: 'https://demo.convex.cloud',
        apiVersion: '0.1.0',
        onConnected: () => const <ClientMessage>[],
        onMessage: (_) => const <ClientMessage>[],
        onDisconnected: (_) async {},
        onConnectionStateChanged: (_, __) {},
        maxObservedTimestamp: () => null,
        hasSyncedPastLastReconnect: () => false,
        reconnectBackoff: const <Duration>[],
        backoffJitter: 0,
        inactivityTimeout: const Duration(seconds: 30),
        logLevel: DartvexLogLevel.info,
        logger: events.add,
      );
    }

    int? lastScheduledDelayMs(List<DartvexLogEvent> events) {
      final schedules = events
          .where((event) => event.message == 'Reconnect scheduled')
          .toList(growable: false);
      if (schedules.isEmpty) {
        return null;
      }
      return schedules.last.data?['delayMs'] as int?;
    }

    test('reconnectNow backs off from the 100ms client base (NF1)', () async {
      final adapter = MockWebSocketAdapter();
      final events = <DartvexLogEvent>[];
      final manager = buildExponentialManager(adapter, events);

      await manager.start();
      await manager.reconnectNow('AppResumed');
      // Capture the scheduled delay before the (100ms) reconnect timer fires.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(lastScheduledDelayMs(events), 100);

      await manager.dispose();
    });

    test('an unexpected server close backs off from the 1s base (NF1)',
        () async {
      final adapter = MockWebSocketAdapter();
      final events = <DartvexLogEvent>[];
      final manager = buildExponentialManager(adapter, events);

      await manager.start();
      // A spontaneous server/network close: no _pendingCloseReason, so it is
      // classified as server/unknown rather than client-initiated.
      adapter.disconnect(code: 1006);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(lastScheduledDelayMs(events), 1000);

      await manager.dispose();
    });

    test('a classified server-overload close uses the overload table (NF1)',
        () async {
      final adapter = MockWebSocketAdapter();
      final events = <DartvexLogEvent>[];
      final manager = buildExponentialManager(adapter, events);

      await manager.start();
      adapter.disconnect(reason: 'SubscriptionsWorkerFullError: overloaded');
      await Future<void>.delayed(const Duration(milliseconds: 10));

      // Server-overload base (3s), not the 100ms client base.
      expect(lastScheduledDelayMs(events), 3000);

      await manager.dispose();
    });

    group('computeExponentialBackoff', () {
      test('starts at the base and doubles per retry index', () {
        expect(
          WebSocketManager.computeExponentialBackoff(
            retryIndex: 0,
            baseBackoffMs: 100,
            maxBackoffMs: 16000,
            jitter: 0,
            randomUnit: 0.5,
          ),
          const Duration(milliseconds: 100),
        );
        expect(
          WebSocketManager.computeExponentialBackoff(
            retryIndex: 3,
            baseBackoffMs: 100,
            maxBackoffMs: 16000,
            jitter: 0,
            randomUnit: 0.5,
          ),
          const Duration(milliseconds: 800),
        );
        expect(
          WebSocketManager.computeExponentialBackoff(
            retryIndex: 0,
            baseBackoffMs: 1000,
            maxBackoffMs: 16000,
            jitter: 0,
            randomUnit: 0.5,
          ),
          const Duration(milliseconds: 1000),
        );
      });

      test('caps at maxBackoff for a large retry index (no overflow wrap)', () {
        expect(
          WebSocketManager.computeExponentialBackoff(
            retryIndex: 100,
            baseBackoffMs: 1000,
            maxBackoffMs: 16000,
            jitter: 0,
            randomUnit: 0.5,
          ),
          const Duration(milliseconds: 16000),
        );
      });

      test('spreads the delay across +/- jitter without going negative', () {
        expect(
          WebSocketManager.computeExponentialBackoff(
            retryIndex: 0,
            baseBackoffMs: 1000,
            maxBackoffMs: 16000,
            jitter: 0.5,
            randomUnit: 0,
          ),
          const Duration(milliseconds: 500),
        );
        expect(
          WebSocketManager.computeExponentialBackoff(
            retryIndex: 0,
            baseBackoffMs: 1000,
            maxBackoffMs: 16000,
            jitter: 0.5,
            randomUnit: 1,
          ),
          const Duration(milliseconds: 1500),
        );
      });
    });

    group('connect attempt supersession', () {
      test(
          'a connect superseded by stop()/restart() never finishes its '
          'handshake on the newer socket', () async {
        final adapter = _QueuedConnectAdapter();
        var connectedCalls = 0;
        final manager = WebSocketManager(
          adapter: adapter,
          deploymentUrl: 'https://demo.convex.cloud',
          apiVersion: '0.1.0',
          onConnected: () {
            connectedCalls += 1;
            return const <ClientMessage>[];
          },
          onMessage: (_) => const <ClientMessage>[],
          onDisconnected: (_) async {},
          onConnectionStateChanged: (_, __) {},
          maxObservedTimestamp: () => null,
          hasSyncedPastLastReconnect: () => false,
          reconnectBackoff: const <Duration>[Duration.zero],
          inactivityTimeout: const Duration(seconds: 30),
        );

        // First connect attempt hangs at the adapter.
        final startFuture = manager.start();
        await Future<void>.delayed(Duration.zero);
        expect(adapter.pendingConnects, hasLength(1));

        // An auth reauth stops the manager mid-connect and restarts it; the
        // restarted attempt also hangs at the adapter.
        await manager.stop();
        final restartFuture = manager.restart();
        await Future<void>.delayed(Duration.zero);
        expect(adapter.pendingConnects, hasLength(2));

        // The newer attempt opens first and runs the handshake.
        adapter.completeConnect(1);
        await restartFuture;

        // The superseded attempt opens late: its continuation must bail out
        // instead of writing a second Connect frame onto the live socket or
        // double-counting the connection.
        adapter.completeConnect(0);
        await startFuture;
        await Future<void>.delayed(Duration.zero);

        final connectFrames = adapter.decodedSentMessages
            .where((message) => message['type'] == 'Connect')
            .toList(growable: false);
        expect(connectFrames, hasLength(1));
        expect(connectedCalls, 1);
        expect(manager.connectionCount, 1);

        await manager.dispose();
      });
    });
  });
}

Future<List<Map<String, dynamic>>> _waitForConnectMessages(
  MockWebSocketAdapter adapter,
  int count,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (DateTime.now().isBefore(deadline)) {
    final messages = adapter.decodedSentMessages
        .where((message) => message['type'] == 'Connect')
        .toList(growable: false);
    if (messages.length >= count) {
      return messages;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return adapter.decodedSentMessages
      .where((message) => message['type'] == 'Connect')
      .toList(growable: false);
}

/// Adapter whose connect() calls each hang on their own completer, so a test
/// can resolve overlapping connect attempts out of order.
class _QueuedConnectAdapter implements WebSocketAdapter {
  final StreamController<String> _messagesController =
      StreamController<String>.broadcast();
  final StreamController<WebSocketCloseEvent> _closeController =
      StreamController<WebSocketCloseEvent>.broadcast(sync: true);

  final List<Completer<void>> pendingConnects = <Completer<void>>[];
  final List<String> sentMessages = <String>[];
  bool _connected = false;

  @override
  Future<void> connect(String url) async {
    final completer = Completer<void>();
    pendingConnects.add(completer);
    await completer.future;
    _connected = true;
  }

  void completeConnect(int index) {
    pendingConnects[index].complete();
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
    _connected = false;
  }

  @override
  bool get isConnected => _connected;
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

class _OnceThrowingSendAdapter extends MockWebSocketAdapter {
  _OnceThrowingSendAdapter({required this.failAtSentCount});

  final int failAtSentCount;
  bool _failed = false;

  @override
  void send(String message) {
    if (!_failed && sentMessages.length == failAtSentCount) {
      _failed = true;
      throw StateError('send failed');
    }
    super.send(message);
  }
}

class _DisconnectingThrowingSendAdapter extends MockWebSocketAdapter {
  _DisconnectingThrowingSendAdapter({required this.failAtSentCount});

  final int failAtSentCount;
  bool _failed = false;

  @override
  void send(String message) {
    if (!_failed && sentMessages.length == failAtSentCount) {
      _failed = true;
      disconnect();
      throw StateError('send failed after disconnect');
    }
    super.send(message);
  }
}

class _SilentDisconnectAdapter extends MockWebSocketAdapter {
  final StreamController<String> _messagesController =
      StreamController<String>.broadcast();
  final StreamController<WebSocketCloseEvent> _closeController =
      StreamController<WebSocketCloseEvent>.broadcast(sync: true);

  final List<String> _sentMessages = <String>[];
  final List<String> _connectedUrls = <String>[];

  @override
  List<String> get sentMessages => _sentMessages;

  @override
  List<String> get connectedUrls => _connectedUrls;

  bool _connected = false;

  @override
  Future<void> connect(String url) async {
    connectedUrls.add(url);
    _connected = true;
  }

  void silentlyDisconnect() {
    _connected = false;
  }

  @override
  void send(String message) {
    if (!_connected) {
      throw StateError('Mock socket is disconnected');
    }
    sentMessages.add(message);
  }

  @override
  List<Map<String, dynamic>> get decodedSentMessages {
    return sentMessages
        .map((message) => jsonDecode(message) as Map<String, dynamic>)
        .toList(growable: false);
  }

  @override
  void pushServerMessage(Map<String, dynamic> message) {
    _messagesController.add(jsonEncode(message));
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

class _HangingThenConnectingAdapter implements WebSocketAdapter {
  final StreamController<String> _messagesController =
      StreamController<String>.broadcast();
  final StreamController<WebSocketCloseEvent> _closeController =
      StreamController<WebSocketCloseEvent>.broadcast(sync: true);
  final Completer<void> _firstHang = Completer<void>();

  final List<String> sentMessages = <String>[];
  final List<String> connectedUrls = <String>[];
  int connectAttempts = 0;
  bool _connected = false;

  @override
  Future<void> connect(String url) async {
    connectedUrls.add(url);
    connectAttempts += 1;
    if (connectAttempts == 1) {
      // Never completes until close() aborts it, simulating a dead handshake.
      await _firstHang.future;
      return;
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
    if (!_firstHang.isCompleted) {
      _firstHang.complete();
    }
    if (_connected) {
      _connected = false;
      _closeController.add(const WebSocketCloseEvent());
    }
  }

  @override
  bool get isConnected => _connected;
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

class _DelayedFailingThenConnectingAdapter implements WebSocketAdapter {
  final StreamController<String> _messagesController =
      StreamController<String>.broadcast();
  final StreamController<WebSocketCloseEvent> _closeController =
      StreamController<WebSocketCloseEvent>.broadcast(sync: true);
  final Completer<void> _firstConnectCompleter = Completer<void>();

  final List<String> sentMessages = <String>[];
  final List<String> connectedUrls = <String>[];
  int connectAttempts = 0;
  bool _connected = false;

  @override
  Future<void> connect(String url) async {
    connectedUrls.add(url);
    connectAttempts += 1;
    if (connectAttempts == 1) {
      await _firstConnectCompleter.future;
      _closeController.add(const WebSocketCloseEvent(code: 1006));
      throw StateError('connect failed');
    }
    _connected = true;
  }

  void failFirstConnect() {
    if (!_firstConnectCompleter.isCompleted) {
      _firstConnectCompleter.complete();
    }
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

class _DelayedConnectingAdapter implements WebSocketAdapter {
  final StreamController<String> _messagesController =
      StreamController<String>.broadcast();
  final StreamController<WebSocketCloseEvent> _closeController =
      StreamController<WebSocketCloseEvent>.broadcast(sync: true);
  final Completer<void> _connectCompleter = Completer<void>();

  final List<String> sentMessages = <String>[];
  final List<String> connectedUrls = <String>[];
  bool _connected = false;

  @override
  Future<void> connect(String url) async {
    connectedUrls.add(url);
    await _connectCompleter.future;
    _connected = true;
  }

  void completeConnect() {
    if (!_connectCompleter.isCompleted) {
      _connectCompleter.complete();
    }
  }

  void disconnect({
    int? code,
    String? reason,
    bool? wasClean,
    String? errorMessage,
  }) {
    _connected = false;
    _closeController.add(
      WebSocketCloseEvent(
        code: code,
        reason: reason,
        wasClean: wasClean,
        errorMessage: errorMessage,
      ),
    );
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
    disconnect();
  }

  @override
  bool get isConnected => _connected;
}
