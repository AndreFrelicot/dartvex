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
        hasSyncedPastLastReconnect: () => false,
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
        hasSyncedPastLastReconnect: () => false,
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
      expect(connectMessages.single['connectionCount'], 0);
      expect(
        connectMessages.single['lastCloseReason'],
        'WebSocket closed with code 1006',
      );

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
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(disconnectReasons, contains('InvalidServerMessage'));
      expect(
        adapter.decodedSentMessages
            .where((message) => message['type'] == 'Connect'),
        hasLength(2),
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
      await Future<void>.delayed(const Duration(milliseconds: 15));
      await deliverMessage();
      adapter.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(scheduledDelays(), <int>[10, 20]);

      // Once the client reports it has re-synced, the next handled message
      // resets the backoff, so the following disconnect schedules from 10ms.
      synced = true;
      await deliverMessage();
      adapter.disconnect();
      await Future<void>.delayed(const Duration(milliseconds: 15));

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
