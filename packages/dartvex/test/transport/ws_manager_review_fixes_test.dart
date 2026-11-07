// Regression tests for the 2026-11 post-release review of the WebSocket
// transport (findings F12, F69-F74, F171-F179, F231-F233, C10).
import 'dart:async';
import 'dart:convert';

import 'package:dartvex/src/logging.dart';
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:dartvex/src/transport/ws_interface.dart';
import 'package:dartvex/src/transport/ws_manager.dart';
import 'package:test/test.dart';

void main() {
  Future<void> waitUntil(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 2),
    String? reason,
  }) async {
    final stopwatch = Stopwatch()..start();
    while (!condition()) {
      if (stopwatch.elapsed > timeout) {
        fail('Timed out waiting: ${reason ?? 'condition'}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<void> settle([int ms = 10]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  WebSocketManager buildManager(
    _ScriptedAdapter adapter, {
    List<Duration> reconnectBackoff = const <Duration>[Duration.zero],
    Duration initialBackoff = const Duration(seconds: 1),
    Duration maxBackoff = const Duration(seconds: 16),
    double backoffJitter = 0,
    Duration inactivityTimeout = const Duration(seconds: 30),
    ConnectedMessageBuilder? onConnected,
    ServerMessageHandler? onMessage,
    DisconnectHandler? onDisconnected,
    ConnectionStateHandler? onConnectionStateChanged,
    SyncedStateGetter? hasSyncedPastLastReconnect,
    TransitionMetricsCallback? onTransitionMetrics,
    void Function()? onStatusChanged,
    ServerDisconnectErrorHandler? onServerDisconnectError,
    List<DartvexLogEvent>? logEvents,
    DartvexLogger? logger,
  }) {
    return WebSocketManager(
      adapter: adapter,
      deploymentUrl: 'https://demo.convex.cloud',
      apiVersion: '0.1.0',
      onConnected: onConnected ?? () => const <ClientMessage>[],
      onMessage: onMessage ?? (_) {},
      onDisconnected: onDisconnected ?? (_) async {},
      onConnectionStateChanged: onConnectionStateChanged ?? (_, __) {},
      maxObservedTimestamp: () => null,
      hasSyncedPastLastReconnect: hasSyncedPastLastReconnect ?? () => false,
      reconnectBackoff: reconnectBackoff,
      initialBackoff: initialBackoff,
      maxBackoff: maxBackoff,
      backoffJitter: backoffJitter,
      inactivityTimeout: inactivityTimeout,
      onTransitionMetrics: onTransitionMetrics,
      onStatusChanged: onStatusChanged,
      onServerDisconnectError: onServerDisconnectError,
      logLevel: (logEvents != null || logger != null)
          ? DartvexLogLevel.debug
          : DartvexLogLevel.off,
      logger: logger ?? logEvents?.add,
    );
  }

  int? lastScheduledDelayMs(List<DartvexLogEvent> events) {
    final schedules = events
        .where((event) => event.message == 'Reconnect scheduled')
        .toList(growable: false);
    return schedules.isEmpty ? null : schedules.last.data?['delayMs'] as int?;
  }

  Map<String, dynamic> transitionJson({double? clientClockSkew = 0}) {
    return Transition(
      startVersion: const StateVersion.initial(),
      endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
      modifications: const <StateModification>[
        QueryUpdated(queryId: 1, value: 'hello'),
      ],
      clientClockSkew: clientClockSkew,
      serverTs: clientClockSkew == null
          ? null
          : (DateTime.now().millisecondsSinceEpoch.toDouble() - 150) * 1e6,
    ).toJson();
  }

  group('reconnectNow during a backoff wait (F12)', () {
    test('replaces a long fixed-schedule wait with the client delay', () async {
      final adapter = _ScriptedAdapter();
      final disconnects = <String>[];
      final events = <DartvexLogEvent>[];
      final manager = buildManager(
        adapter,
        reconnectBackoff: const <Duration>[Duration(hours: 1)],
        onDisconnected: (reason) async => disconnects.add(reason),
        logEvents: events,
      );

      await manager.start();
      adapter.serverClose(code: 1011, reason: 'InternalServerError: boom');
      await settle();
      expect(lastScheduledDelayMs(events),
          const Duration(hours: 1).inMilliseconds);

      final stopwatch = Stopwatch()..start();
      await manager.reconnectNow('AppResumed');
      await waitUntil(() => adapter.connectCalls == 2, reason: 'reconnect');
      expect(stopwatch.elapsedMilliseconds, lessThan(1000));
      expect(lastScheduledDelayMs(events), 100);
      // The disconnect was reported exactly once, and the real cause is still
      // what the next Connect reports.
      expect(disconnects, <String>['InternalServerError: boom']);
      await waitUntil(() => adapter.connectMessages.length == 2);
      expect(
        adapter.connectMessages.last['lastCloseReason'],
        'InternalServerError: boom',
      );

      await manager.dispose();
    });

    test('replaces a long exponential wait without advancing the progression',
        () async {
      final adapter = _ScriptedAdapter();
      final events = <DartvexLogEvent>[];
      final manager = buildManager(
        adapter,
        reconnectBackoff: const <Duration>[],
        initialBackoff: const Duration(seconds: 10),
        maxBackoff: const Duration(seconds: 16),
        logEvents: events,
      );

      await manager.start();
      adapter.serverClose(code: 1006);
      await settle();
      expect(lastScheduledDelayMs(events), 10000);
      expect(manager.connectionRetries, 1);

      await manager.reconnectNow('AppResumed');
      expect(lastScheduledDelayMs(events), 100);
      expect(manager.connectionRetries, 1);
      await waitUntil(() => adapter.connectCalls == 2, reason: 'reconnect');

      await manager.dispose();
    });

    test('is a no-op while stopped for a reauth', () async {
      final adapter = _ScriptedAdapter();
      final manager = buildManager(adapter);

      await manager.start();
      await manager.stop();
      await manager.reconnectNow('AppResumed');
      await settle(30);
      expect(adapter.connectCalls, 1);

      await manager.restart();
      expect(adapter.connectCalls, 2);
      await manager.dispose();
    });
  });

  group('client-initiated closes (F69)', () {
    test('reconnect without waiting for the platform close event', () async {
      final adapter = _ScriptedAdapter()..emitCloseOnClose = false;
      final disconnects = <String>[];
      final manager = buildManager(
        adapter,
        onDisconnected: (reason) async => disconnects.add(reason),
      );

      await manager.start();
      await manager.reconnectNow('AppResumed');
      await waitUntil(() => adapter.connectCalls == 2, reason: 'reconnect');
      expect(disconnects, <String>['AppResumed']);

      // A late platform close event for the old socket is ignored.
      adapter.emitLateClose();
      await settle();
      expect(disconnects, <String>['AppResumed']);
      expect(adapter.connectCalls, 2);

      await manager.dispose();
    });

    test('an inactivity timeout reconnects even if no close event arrives',
        () async {
      final adapter = _ScriptedAdapter()..emitCloseOnClose = false;
      final disconnects = <String>[];
      final manager = buildManager(
        adapter,
        inactivityTimeout: const Duration(milliseconds: 30),
        onDisconnected: (reason) async => disconnects.add(reason),
      );

      await manager.start();
      await waitUntil(() => adapter.connectCalls >= 2, reason: 'reconnect');
      expect(disconnects.first, 'InactiveServer');
      await waitUntil(() => adapter.connectMessages.length >= 2);
      expect(adapter.connectMessages[1]['lastCloseReason'], 'InactiveServer');

      await manager.dispose();
    });
  });

  group('connect that returns without an open socket (F70)', () {
    test('is treated as a failed attempt and retried', () async {
      final adapter = _ScriptedAdapter()..openOnConnect = false;
      final disconnects = <String>[];
      final manager = buildManager(
        adapter,
        onDisconnected: (reason) async => disconnects.add(reason),
      );

      await manager.start();
      await waitUntil(() => adapter.connectCalls >= 2, reason: 'retry');
      expect(disconnects, isNotEmpty);
      expect(disconnects.first, contains('not open'));

      adapter.openOnConnect = true;
      await waitUntil(() => adapter.connected, reason: 'eventual connect');
      await manager.dispose();
    });

    test('an inactivity timer never closes a socket it did not watch',
        () async {
      final adapter = _ScriptedAdapter();
      final manager = buildManager(
        adapter,
        reconnectBackoff: const <Duration>[Duration(hours: 1)],
        inactivityTimeout: const Duration(milliseconds: 20),
      );

      await manager.start();
      adapter.serverClose(code: 1006);
      await settle(60);
      // Disconnected and waiting: no inactivity close was attempted.
      expect(adapter.closeCalls, 0);
      await manager.dispose();
    });
  });

  test('a throwing onTransitionMetrics callback cannot drop a Transition (F71)',
      () async {
    final adapter = _ScriptedAdapter();
    final received = <ServerMessage>[];
    final disconnects = <String>[];
    final manager = buildManager(
      adapter,
      onMessage: received.add,
      onDisconnected: (reason) async => disconnects.add(reason),
      onTransitionMetrics: (_) => throw StateError('widget disposed'),
    );

    await manager.start();
    adapter.push(transitionJson());
    await settle();

    expect(received.single, isA<Transition>());
    expect(disconnects, isEmpty);
    expect(adapter.connectCalls, 1);
    await manager.dispose();
  });

  group('computeExponentialBackoff (F72)', () {
    test('a zero base never produces NaN, even at huge retry indexes', () {
      for (final retryIndex in <int>[0, 63, 64, 1023, 1024, 100000]) {
        expect(
          WebSocketManager.computeExponentialBackoff(
            retryIndex: retryIndex,
            baseBackoffMs: 0,
            maxBackoffMs: 16000,
            jitter: 0.5,
            randomUnit: 0.9,
          ),
          Duration.zero,
        );
      }
    });

    test('a positive base saturates at the cap for huge retry indexes', () {
      expect(
        WebSocketManager.computeExponentialBackoff(
          retryIndex: 1024,
          baseBackoffMs: 100,
          maxBackoffMs: 16000,
          jitter: 0,
          randomUnit: 0.5,
        ),
        const Duration(seconds: 16),
      );
    });

    test('zero initialBackoff keeps reconnecting past 1024 retries', () async {
      final adapter = _ScriptedAdapter()..failConnects = 1100;
      final manager = buildManager(
        adapter,
        reconnectBackoff: const <Duration>[],
        initialBackoff: Duration.zero,
        maxBackoff: Duration.zero,
      );

      unawaited(manager.start());
      await waitUntil(
        () => adapter.connected,
        timeout: const Duration(seconds: 20),
        reason: 'connect after 1100 failures',
      );
      expect(adapter.connectCalls, 1101);
      await manager.dispose();
    });
  });

  test('a close is handled after frames that arrived before it (F73)',
      () async {
    final adapter = _ScriptedAdapter();
    final order = <String>[];
    final manager = buildManager(
      adapter,
      onMessage: (message) async {
        // A handler that yields, as the production handler does.
        await Future<void>.delayed(Duration.zero);
        order.add('message:${message.runtimeType}');
      },
      onDisconnected: (reason) async => order.add('disconnect'),
    );

    await manager.start();
    // Same task: the response frame, then the server's close.
    adapter.push(const ActionResponse(requestId: 1, success: true).toJson());
    adapter.serverClose(code: 1001);
    await settle();

    expect(order, <String>['message:ActionResponse', 'disconnect']);
    await manager.dispose();
  });

  test('connectionRetries keeps counting past a fixed schedule (F74, F176)',
      () async {
    final adapter = _ScriptedAdapter();
    var statusNotifications = 0;
    var synced = false;
    final manager = buildManager(
      adapter,
      reconnectBackoff: const <Duration>[Duration.zero],
      hasSyncedPastLastReconnect: () => synced,
      onStatusChanged: () => statusNotifications += 1,
    );

    await manager.start();
    for (var i = 1; i <= 3; i++) {
      adapter.serverClose(code: 1006);
      await waitUntil(() => adapter.connectCalls == i + 1);
      await waitUntil(() => adapter.connected);
    }
    expect(manager.connectionRetries, 3);
    expect(statusNotifications, 3);

    synced = true;
    adapter.push(transitionJson(clientClockSkew: null));
    await settle();
    expect(manager.connectionRetries, 0);
    // The reset is republished even though no connection state changed.
    expect(statusNotifications, 4);

    await manager.dispose();
  });

  group('Connect.lastCloseReason parity (F171)', () {
    test('is cleared after a successful open, so stop/restart reports none',
        () async {
      final adapter = _ScriptedAdapter();
      final manager = buildManager(adapter);

      await manager.start();
      await manager.stop();
      await manager.restart();

      expect(adapter.connectMessages, hasLength(2));
      expect(adapter.connectMessages[0]['lastCloseReason'], 'InitialConnect');
      expect(adapter.connectMessages[1]['lastCloseReason'], isNull);
      await manager.dispose();
    });

    test('keeps the first server reason across failed attempts', () async {
      final adapter = _ScriptedAdapter();
      final manager = buildManager(adapter);

      await manager.start();
      adapter.failConnects = 2;
      adapter.serverClose(code: 4000, reason: 'SubscriptionsWorkerFullError');
      await waitUntil(() => adapter.connectMessages.length == 2);

      expect(
        adapter.connectMessages.last['lastCloseReason'],
        'SubscriptionsWorkerFullError',
      );
      await manager.dispose();
    });
  });

  test(
      'frames queued from a stopped socket are not applied after restart '
      '(F172)', () async {
    final adapter = _ScriptedAdapter();
    late final WebSocketManager manager;
    final received = <String>[];
    manager = buildManager(
      adapter,
      onMessage: (message) async {
        received.add(message.runtimeType.toString());
        if (message is FatalError) {
          // Mirrors an AuthError reauth: stop, fetch a token, restart.
          await manager.stop();
          await Future<void>.delayed(const Duration(milliseconds: 5));
          await manager.restart();
        }
      },
    );

    await manager.start();
    adapter.push(const FatalError(error: 'auth expired').toJson());
    adapter.push(transitionJson(clientClockSkew: null));
    await waitUntil(() => adapter.connectCalls == 2);
    await settle();

    expect(received, <String>['FatalError']);
    // Frames from the new socket are processed normally.
    adapter.push(transitionJson(clientClockSkew: null));
    await settle();
    expect(received, <String>['FatalError', 'Transition']);
    await manager.dispose();
  });

  test('a throwing logger cannot wedge connects or the message queue (F173)',
      () async {
    final adapter = _ScriptedAdapter();
    final received = <ServerMessage>[];
    final manager = buildManager(
      adapter,
      onMessage: received.add,
      logger: (_) => throw StateError('closed IOSink'),
    );

    await manager.start();
    expect(adapter.connected, isTrue);
    adapter.push('not json');
    await settle();
    await waitUntil(() => adapter.connectCalls == 2 && adapter.connected);
    adapter.push(transitionJson(clientClockSkew: null));
    await settle();
    expect(received.single, isA<Transition>());
    await manager.dispose();
  });

  test('stop() publishes a disconnect while the reauth runs (F174)', () async {
    final adapter = _ScriptedAdapter();
    final states = <(bool, bool)>[];
    final manager = buildManager(
      adapter,
      onConnectionStateChanged: (connected, reconnecting) =>
          states.add((connected, reconnecting)),
    );

    await manager.start();
    states.clear();
    await manager.stop();
    expect(states, <(bool, bool)>[(false, false)]);
    await manager.restart();
    expect(
        states, <(bool, bool)>[(false, false), (false, true), (true, false)]);
    await manager.dispose();
  });

  test(
      'client-initiated reconnects stay prompt under a long fixed schedule '
      '(F177)', () async {
    final adapter = _ScriptedAdapter();
    final events = <DartvexLogEvent>[];
    final manager = buildManager(
      adapter,
      reconnectBackoff: const <Duration>[Duration(seconds: 30)],
      logEvents: events,
    );

    await manager.start();
    await manager.reconnectNow('AppResumed');
    expect(lastScheduledDelayMs(events), 100);
    await waitUntil(() => adapter.connectCalls == 2);

    // A server close still uses the configured schedule verbatim.
    await waitUntil(() => adapter.connected);
    adapter.serverClose(code: 1006);
    await settle();
    expect(lastScheduledDelayMs(events), 30000);
    await manager.dispose();
  });

  test('a failing Connect send reconnects instead of escaping (F179)',
      () async {
    final adapter = _ScriptedAdapter()..failSends = 1;
    final disconnects = <String>[];
    final manager = buildManager(
      adapter,
      onDisconnected: (reason) async => disconnects.add(reason),
    );

    await manager.start();
    await waitUntil(() => adapter.connectMessages.isNotEmpty);
    expect(disconnects, <String>['FailedToSendMessage']);
    expect(adapter.connectMessages.single['lastCloseReason'],
        'FailedToSendMessage');
    await manager.dispose();
  });

  test('utf8EncodedLength matches utf8.encode (F231)', () {
    for (final value in <String>[
      '',
      'ascii only',
      'café über',
      '€中文',
      'emoji \u{1F600}\u{1F680}',
      'lone high \uD800 surrogate',
      'lone low \uDC00 surrogate',
      'trailing high \uD83D',
    ]) {
      expect(
        WebSocketManager.utf8EncodedLength(value),
        utf8.encode(value).length,
        reason: value,
      );
    }
  });

  test('an async handshake whose socket closed meanwhile is abandoned (F232)',
      () async {
    final adapter = _ScriptedAdapter();
    final connected = <(bool, bool)>[];
    final firstBuild = Completer<List<ClientMessage>>();
    var builds = 0;
    const restore = ModifyQuerySet(
      baseVersion: 0,
      newVersion: 1,
      modifications: <QuerySetOperation>[],
    );
    final manager = buildManager(
      adapter,
      onConnected: () {
        builds += 1;
        if (builds == 1) {
          return firstBuild.future;
        }
        return const <ClientMessage>[restore];
      },
      onConnectionStateChanged: (connected_, reconnecting) {
        if (connected_) {
          connected.add((connected_, reconnecting));
        }
      },
    );

    unawaited(manager.start());
    await waitUntil(() => builds == 1);
    adapter.serverClose(code: 1006);
    await waitUntil(() => builds == 2 && connected.length == 1);
    // The first handshake's continuation resumes on the replaced socket.
    firstBuild.complete(const <ClientMessage>[restore]);
    await settle();

    final restores = adapter.decoded
        .where((message) => message['type'] == 'ModifyQuerySet')
        .toList(growable: false);
    expect(restores, hasLength(1));
    expect(connected, hasLength(1));
    expect(manager.connectionCount, 1);
    await manager.dispose();
  });

  test(
      'a pause raised synchronously while the handshake messages are built '
      'does not drop them', () async {
    final adapter = _ScriptedAdapter();
    var builds = 0;
    late WebSocketManager manager;
    const restore = ModifyQuerySet(
      baseVersion: 0,
      newVersion: 1,
      modifications: <QuerySetOperation>[],
    );
    manager = buildManager(
      adapter,
      onConnected: () {
        builds += 1;
        if (builds == 1) {
          // A listener notified while the reconnect state is rebuilt starts
          // an auth flow, which pauses the socket before the messages are
          // sent.
          manager.pause();
        }
        return const <ClientMessage>[restore];
      },
    );

    await manager.start();
    await settle();
    // The socket is paused: nothing may be sent until resume().
    await manager.resume();
    await waitUntil(
      () => adapter.decoded.any((m) => m['type'] == 'ModifyQuerySet'),
      reason: 'session-restoring messages sent after resume',
    );

    // The restoring messages follow a Connect on the socket they reach.
    final types = adapter.decoded.map((m) => m['type']).toList();
    final restoreIndex = types.lastIndexOf('ModifyQuerySet');
    expect(types.sublist(0, restoreIndex).contains('Connect'), isTrue);
    expect(types.where((t) => t == 'ModifyQuerySet'), hasLength(1));
    await manager.dispose();
  });

  test(
      'a connectivity-restore reconnect reports NetworkRecoveryReconnect '
      '(F233)', () async {
    final adapter = _ScriptedAdapter();
    final manager = buildManager(
      adapter,
      reconnectBackoff: const <Duration>[Duration(hours: 1)],
    );

    await manager.start();
    adapter.serverClose(code: 1006);
    await settle();
    manager.reconnectImmediatelyIfWaiting();
    await waitUntil(() => adapter.connectMessages.length == 2);
    await settle();

    final events = adapter.decoded
        .where((message) => message['type'] == 'Event')
        .toList(growable: false);
    expect(events, hasLength(1));
    expect(events.single['eventType'], 'NetworkRecoveryReconnect');
    final timeSaved = (events.single['event'] as Map)['timeSavedMs'] as num;
    expect(timeSaved, greaterThan(const Duration(minutes: 59).inMilliseconds));

    // Not repeated on later reconnects.
    adapter.serverClose(code: 1006);
    await settle();
    await manager.reconnectNow('AppResumed');
    await waitUntil(() => adapter.connectMessages.length == 3);
    await settle();
    expect(
      adapter.decoded.where((message) => message['type'] == 'Event'),
      hasLength(1),
    );
    await manager.dispose();
  });

  group('onServerDisconnectError (C10)', () {
    test('reports abnormal server closes that carry a reason', () async {
      final adapter = _ScriptedAdapter();
      final reported = <String>[];
      final manager = buildManager(
        adapter,
        onServerDisconnectError: reported.add,
      );

      await manager.start();
      adapter.serverClose(code: 1011, reason: 'InternalServerError');
      await waitUntil(() => adapter.connectCalls == 2 && adapter.connected);
      // Expected codes and reason-less closes are not reported.
      adapter.serverClose(code: 1000, reason: 'bye');
      await waitUntil(() => adapter.connectCalls == 3 && adapter.connected);
      adapter.serverClose(code: 1006);
      await waitUntil(() => adapter.connectCalls == 4 && adapter.connected);
      // Neither are client-initiated closes.
      await manager.reconnectNow('AppResumed');
      await waitUntil(() => adapter.connectCalls == 5 && adapter.connected);

      expect(reported, <String>[
        'WebSocket closed with code 1011: InternalServerError',
      ]);
      await manager.dispose();
    });

    test('a throwing callback does not break reconnects', () async {
      final adapter = _ScriptedAdapter();
      final manager = buildManager(
        adapter,
        onServerDisconnectError: (_) => throw StateError('telemetry down'),
      );

      await manager.start();
      adapter.serverClose(code: 1011, reason: 'InternalServerError');
      await waitUntil(() => adapter.connectCalls == 2 && adapter.connected);
      await manager.dispose();
    });
  });
}

/// A scriptable in-memory adapter.
class _ScriptedAdapter implements WebSocketAdapter {
  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final StreamController<WebSocketCloseEvent> _closes =
      StreamController<WebSocketCloseEvent>.broadcast();

  final List<String> sent = <String>[];
  int connectCalls = 0;
  int closeCalls = 0;
  bool connected = false;

  /// Whether [close] emits a close event (a real platform eventually does,
  /// but possibly only after a long closing-handshake timeout).
  bool emitCloseOnClose = true;

  /// Whether [connect] leaves an open socket behind.
  bool openOnConnect = true;

  /// Number of upcoming [connect] calls that fail.
  int failConnects = 0;

  /// Number of upcoming [send] calls that throw.
  int failSends = 0;

  List<Map<String, dynamic>> get decoded => sent
      .map((message) => jsonDecode(message) as Map<String, dynamic>)
      .toList(growable: false);

  List<Map<String, dynamic>> get connectMessages => decoded
      .where((message) => message['type'] == 'Connect')
      .toList(growable: false);

  @override
  Future<void> connect(String url) async {
    connectCalls += 1;
    if (failConnects > 0) {
      failConnects -= 1;
      throw StateError('connect failed');
    }
    if (openOnConnect) {
      connected = true;
    }
  }

  @override
  void send(String message) {
    if (!connected) {
      throw StateError('socket closed');
    }
    if (failSends > 0) {
      failSends -= 1;
      throw StateError('send failed');
    }
    sent.add(message);
  }

  void push(Object message) {
    _messages.add(message is String ? message : jsonEncode(message));
  }

  void serverClose({int? code, String? reason}) {
    connected = false;
    _closes.add(WebSocketCloseEvent(code: code, reason: reason));
  }

  void emitLateClose() {
    _closes.add(const WebSocketCloseEvent(code: 1006));
  }

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<WebSocketCloseEvent> get closeEvents => _closes.stream;

  @override
  Future<void> close() async {
    closeCalls += 1;
    if (!connected) {
      return;
    }
    connected = false;
    if (emitCloseOnClose) {
      _closes.add(const WebSocketCloseEvent(code: 1000));
    }
  }

  @override
  bool get isConnected => connected;
}
