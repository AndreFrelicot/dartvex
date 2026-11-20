import 'dart:async';

import 'package:dartvex/dartvex.dart';
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:test/test.dart';

import 'test_helpers/mock_web_socket_adapter.dart';

/// Cached-seed marking, `ConvexWatch.watch` and `ConvexClientWithAuth.clearAuth`.
void main() {
  Future<void> settle() async {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  ConvexClient newClient(MockWebSocketAdapter adapter,
      {bool expectAuth = false}) {
    return ConvexClient(
      'https://demo.convex.cloud',
      config: ConvexClientConfig(
        adapterFactory: (_) => adapter,
        reconnectBackoff: const <Duration>[Duration.zero],
        expectAuth: expectAuth,
      ),
    );
  }

  List<Map<String, dynamic>> querySets(MockWebSocketAdapter adapter) =>
      adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .toList();

  int lastAddedQueryId(MockWebSocketAdapter adapter) {
    final add = querySets(adapter)
        .expand((set) => (set['modifications'] as List<dynamic>))
        .cast<Map<String, dynamic>>()
        .lastWhere((modification) => modification['type'] == 'Add');
    return add['queryId'] as int;
  }

  int querySetVersion(MockWebSocketAdapter adapter) =>
      querySets(adapter).last['newVersion'] as int;

  bool removed(MockWebSocketAdapter adapter, int queryId) => querySets(adapter)
      .expand((set) => (set['modifications'] as List<dynamic>))
      .cast<Map<String, dynamic>>()
      .any((m) => m['type'] == 'Remove' && m['queryId'] == queryId);

  var ts = 0;
  StateVersion? last;

  /// Pushes a transition from the previous one to the current query set.
  void push(MockWebSocketAdapter adapter, List<StateModification> mods) {
    final start = last ?? const StateVersion.initial();
    final end = StateVersion(
      querySet: querySetVersion(adapter),
      identity: start.identity,
      ts: encodeTs(++ts),
    );
    adapter.pushServerMessage(
      Transition(startVersion: start, endVersion: end, modifications: mods)
          .toJson(),
    );
    last = end;
  }

  setUp(() {
    ts = 0;
    last = null;
  });

  /// Subscribes once, answers [value], then unsubscribes so the result lands
  /// in the after-unsubscribe cache.
  Future<void> warmCache(
    ConvexClient client,
    MockWebSocketAdapter adapter,
    String name,
    StateModification Function(int queryId) answer,
  ) async {
    final first = client.subscribe(name);
    final firstValue = first.stream
        .firstWhere((result) => result is! QueryLoading)
        .timeout(const Duration(seconds: 1));
    await settle();
    push(adapter, <StateModification>[answer(lastAddedQueryId(adapter))]);
    await firstValue;
    first.cancel();
    await settle();
  }

  group('cached seed marking', () {
    test('a new subscription marks the warm cache seed as fromCache', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      await warmCache(
        client,
        adapter,
        'messages:list',
        (id) => QueryUpdated(queryId: id, value: 'old'),
      );

      final second = client.subscribe('messages:list');
      final results = <QueryResult>[];
      final listening = second.stream.listen(results.add);
      await settle();
      push(adapter, <StateModification>[
        QueryUpdated(queryId: lastAddedQueryId(adapter), value: 'new'),
      ]);
      await settle();

      final successes = results.whereType<QuerySuccess>().toList();
      expect(successes.map((r) => r.value), <Object>['old', 'new']);
      expect(successes.map((r) => r.fromCache), <bool>[true, false]);

      await listening.cancel();
      second.cancel();
      await client.close();
    });

    test('a cached error seed is marked fromCache', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      await warmCache(
        client,
        adapter,
        'messages:list',
        (id) => QueryFailed(queryId: id, errorMessage: 'boom'),
      );

      final second = client.subscribe('messages:list');
      final seed =
          await second.stream.first.timeout(const Duration(seconds: 1));
      expect(
        seed,
        isA<QueryError>()
            .having((e) => e.message, 'message', 'boom')
            .having((e) => e.fromCache, 'fromCache', isTrue),
      );

      second.cancel();
      await client.close();
    });

    test('a value shared with a live subscription is not fromCache', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      final first = client.subscribe('messages:list');
      final firstValue = first.stream
          .firstWhere((result) => result is QuerySuccess)
          .timeout(const Duration(seconds: 1));
      await settle();
      push(adapter, <StateModification>[
        QueryUpdated(queryId: lastAddedQueryId(adapter), value: 'live'),
      ]);
      await firstValue;

      final second = client.subscribe('messages:list');
      final seed =
          await second.stream.first.timeout(const Duration(seconds: 1));
      expect(
        seed,
        isA<QuerySuccess>()
            .having((r) => r.value, 'value', 'live')
            .having((r) => r.fromCache, 'fromCache', isFalse),
      );

      first.cancel();
      second.cancel();
      await client.close();
    });
  });

  group('watch', () {
    test('decodes values, skips loading, and unsubscribes on cancel', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();

      final values = <int>[];
      final listening = client
          .watch<int>(
            'counters:get',
            const <String, dynamic>{},
            decode: (value) => (value as int) * 10,
          )
          .listen(values.add);
      await settle();
      final queryId = lastAddedQueryId(adapter);
      push(adapter, <StateModification>[
        QueryUpdated(queryId: queryId, value: 1),
      ]);
      await settle();
      push(adapter, <StateModification>[
        QueryUpdated(queryId: queryId, value: 2),
      ]);
      await settle();
      expect(values, <int>[10, 20]);

      await listening.cancel();
      await settle();
      expect(removed(adapter, queryId), isTrue);
      await client.close();
    });

    test('first resolves with the first value and unsubscribes', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();

      final first =
          client.watch<String>('config:get', const <String, dynamic>{}).first;
      await settle();
      final queryId = lastAddedQueryId(adapter);
      push(adapter, <StateModification>[
        QueryUpdated(queryId: queryId, value: 'on'),
      ]);
      expect(await first.timeout(const Duration(seconds: 1)), 'on');
      await settle();
      expect(removed(adapter, queryId), isTrue);
      await client.close();
    });

    test('query errors become ConvexException stream errors, stream stays open',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();

      final events = <Object>[];
      final listening = client.watch<String>('config:get',
          const <String, dynamic>{}).listen(events.add, onError: events.add);
      await settle();
      final queryId = lastAddedQueryId(adapter);
      push(adapter, <StateModification>[
        QueryFailed(
          queryId: queryId,
          errorMessage: 'denied',
          errorData: const <String, dynamic>{'code': 'FORBIDDEN'},
        ),
      ]);
      await settle();
      push(adapter, <StateModification>[
        QueryUpdated(queryId: queryId, value: 'ok'),
      ]);
      await settle();

      expect(events, hasLength(2));
      expect(
        events.first,
        isA<ConvexException>()
            .having((e) => e.message, 'message', 'denied')
            .having((e) => (e.data as Map)['code'], 'code', 'FORBIDDEN'),
      );
      expect(events.last, 'ok');

      await listening.cancel();
      await client.close();
    });

    test('a decode error is a stream error and later values still arrive',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();

      final events = <Object>[];
      final listening = client
          .watch<int>(
            'counters:get',
            const <String, dynamic>{},
            decode: (value) => value as int,
          )
          .listen(events.add, onError: events.add);
      await settle();
      final queryId = lastAddedQueryId(adapter);
      push(adapter, <StateModification>[
        QueryUpdated(queryId: queryId, value: 'not an int'),
      ]);
      await settle();
      push(adapter, <StateModification>[
        QueryUpdated(queryId: queryId, value: 3),
      ]);
      await settle();

      expect(events.first, isA<TypeError>());
      expect(events.last, 3);
      await listening.cancel();
      await client.close();
    });

    test('skipCached drops the warm cache seed, so first waits for the server',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      await settle();
      await warmCache(
        client,
        adapter,
        'conversations:list',
        (id) => QueryUpdated(queryId: id, value: 'stale'),
      );

      // Without skipCached, first resolves with the stale seed.
      expect(
        await client
            .watch<String>('conversations:list', const <String, dynamic>{})
            .first
            .timeout(const Duration(seconds: 1)),
        'stale',
      );
      await settle();

      var resolved = false;
      final fresh = client
          .watch<String>(
            'conversations:list',
            const <String, dynamic>{},
            skipCached: true,
          )
          .first
        ..then((_) => resolved = true);
      await settle();
      expect(resolved, isFalse);
      push(adapter, <StateModification>[
        QueryUpdated(queryId: lastAddedQueryId(adapter), value: 'fresh'),
      ]);
      expect(await fresh.timeout(const Duration(seconds: 1)), 'fresh');
      await client.close();
    });

    test('works through ConvexClientWithAuth', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      final authed = client.withAuth(_NoSessionProvider());
      await settle();

      final first =
          authed.watch<int>('counters:get', const <String, dynamic>{}).first;
      await settle();
      push(adapter, <StateModification>[
        QueryUpdated(queryId: lastAddedQueryId(adapter), value: 7),
      ]);
      expect(await first.timeout(const Duration(seconds: 1)), 7);
      authed.dispose();
      await client.close();
    });
  });

  group('ConvexClientWithAuth.clearAuth', () {
    test('releases an expectAuth hold without calling the provider', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter, expectAuth: true);
      final provider = _NoSessionProvider();
      final authed = client.withAuth(provider);
      final states = <AuthState<String>>[];
      authed.authState.listen(states.add);

      final subscription = authed.subscribe('messages:list');
      await settle();
      expect(querySets(adapter), isEmpty);

      await authed.clearAuth();
      await settle();

      expect(querySets(adapter), isNotEmpty);
      expect(
        adapter.decodedSentMessages.map((m) => m['type']),
        isNot(contains('Authenticate')),
      );
      expect(states.last, isA<AuthUnauthenticated<String>>());
      expect(authed.currentAuthState, isA<AuthUnauthenticated<String>>());
      expect(provider.logoutCalls, 0);

      subscription.cancel();
      authed.dispose();
      await client.close();
    });

    test('supersedes a pending login', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      final provider = _NoSessionProvider();
      final authed = client.withAuth(provider);
      await settle();

      final login = authed.login();
      await settle();
      expect(authed.currentAuthState, isA<AuthLoading<String>>());

      await authed.clearAuth();
      provider.pendingLogin.complete('alice');
      await login;
      await settle();

      expect(authed.currentAuthState, isA<AuthUnauthenticated<String>>());
      expect(client.currentAuthToken, isNull);

      authed.dispose();
      await client.close();
    });

    test('throws on a disposed client', () async {
      final adapter = MockWebSocketAdapter();
      final client = newClient(adapter);
      final authed = client.withAuth(_NoSessionProvider())..dispose();
      expect(authed.clearAuth, throwsA(isA<ConvexException>()));
      await client.close();
    });
  });
}

final class _NoSession extends StateError implements AuthSessionEndedError {
  _NoSession() : super('no session');
}

class _NoSessionProvider implements AuthProvider<String> {
  final Completer<String> pendingLogin = Completer<String>();
  int logoutCalls = 0;

  @override
  String extractIdToken(String authResult) => 'token-$authResult';

  @override
  Future<String> login({required void Function(String? token) onIdToken}) =>
      pendingLogin.future;

  @override
  Future<String> loginFromCache({
    required void Function(String? token) onIdToken,
  }) async =>
      throw _NoSession();

  @override
  Future<void> logout() async {
    logoutCalls++;
  }
}
