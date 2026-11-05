import 'dart:async';

import 'package:dartvex/dartvex.dart';
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:test/test.dart';

import 'test_helpers/mock_web_socket_adapter.dart';

void main() {
  late MockWebSocketAdapter socket;
  late ConvexClient client;
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 10));
  var version = const StateVersion.initial();
  var timestamp = 0;

  Future<void> update(int identity, Object? value) async {
    final querySet = socket.decodedSentMessages
        .where((m) => m['type'] == 'ModifyQuerySet')
        .last;
    final id = (querySet['modifications'] as List).first['queryId'] as int;
    final next = StateVersion(
        querySet: querySet['newVersion'] as int,
        identity: identity,
        ts: encodeTs(++timestamp));
    socket.pushServerMessage(Transition(
      startVersion: version,
      endVersion: next,
      modifications: [QueryUpdated(queryId: id, value: value)],
    ).toJson());
    version = next;
    await settle();
  }

  setUp(() async {
    socket = MockWebSocketAdapter();
    client = ConvexClient('https://demo.convex.cloud',
        config: ConvexClientConfig(adapterFactory: (_) => socket));
    version = const StateVersion.initial();
    timestamp = 0;
    addTearDown(client.close);
    await settle();
    await client.setAuth('alice');
  });

  test('live subscribers and new readers wait for the new identity', () async {
    final events = <QueryResult>[];
    final subscription = client.subscribe('profile:me');
    final listener = subscription.stream.listen(events.add);
    addTearDown(listener.cancel);
    await settle();
    await update(1, 'alice');
    expect(events.last, isA<QuerySuccess>());

    await client.updateAuthToken('refreshed alice');
    expect(events.last, isA<QuerySuccess>());
    await update(2, 'alice');
    await client.clearAuth();
    expect(events.last, isA<QueryLoading>());
    final newEvents = <QueryResult>[];
    final newListener =
        client.subscribe('profile:me').stream.listen(newEvents.add);
    addTearDown(newListener.cancel);
    var completed = false;
    final query = client.query('profile:me').then((value) {
      completed = true;
      return value;
    });
    await update(2, 'late alice');
    expect(completed, isFalse);
    expect(newEvents.whereType<QuerySuccess>(), isEmpty);
    await update(3, 'public');
    expect(await query, 'public');
    expect((events.last as QuerySuccess).value, 'public');
  });

  for (final sameSubscription in <bool>[false, true]) {
    test(
        'reentrant sign-out blocks stale delivery to later listeners (shared: $sameSubscription)',
        () async {
      final first = client.subscribe('profile:me');
      final second = sameSubscription ? first : client.subscribe('profile:me');
      final firstListener = first.stream.listen((event) {
        if (event is QuerySuccess) {
          unawaited(client.clearAuth());
        }
      });
      final events = <QueryResult>[];
      final secondListener = second.stream.listen(events.add);
      addTearDown(firstListener.cancel);
      addTearDown(secondListener.cancel);
      await settle();
      await update(1, 'alice secret');
      expect(events.whereType<QuerySuccess>(), isEmpty);
      expect(events.last, isA<QueryLoading>());
      expect(client.currentAuthToken, isNull);
      expect(client.isAuthenticated, isFalse);
    });
  }

  test(
      'loading listener can replace the auth flow without the outer call overwriting it',
      () async {
    final subscription = client.subscribe('profile:me');
    var replace = false;
    final listener = subscription.stream.listen((event) {
      if (replace && event is QueryLoading) {
        replace = false;
        unawaited(client.setAuth('bob'));
      }
    });
    addTearDown(listener.cancel);
    await settle();
    await update(1, 'alice');
    replace = true;
    await client.clearAuth();
    expect(client.currentAuthToken, 'bob');
    await update(3, 'bob');
    expect(client.isAuthenticated, isTrue);
  });

  for (final refresh in <bool>[false, true]) {
    test(
        'a reentrant token change cannot confirm the new token from the old transition (refresh: $refresh)',
        () async {
      final subscription = client.subscribe('profile:me');
      final listener = subscription.stream.listen((event) {
        if (event is QuerySuccess && event.value == 'alice') {
          unawaited(
              refresh ? client.updateAuthToken('bob') : client.setAuth('bob'));
        }
      });
      addTearDown(listener.cancel);
      await settle();
      await update(1, 'alice');
      expect(client.currentAuthToken, 'bob');
      expect(client.isAuthenticated, isFalse);
      await update(2, 'bob');
      expect(client.isAuthenticated, isTrue);
    });
  }
}
