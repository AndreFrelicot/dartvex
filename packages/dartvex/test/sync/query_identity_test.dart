import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:dartvex/src/sync/base_client.dart';
import 'package:dartvex/src/sync/remote_query_set.dart';
import 'package:test/test.dart';

class _Session {
  final client = BaseClient();
  late final query = client.subscribe('profile:me', {});
  StateVersion version = const StateVersion.initial();
  int timestamp = 0;

  BaseClientReceiveResult transition(
      int identity, List<StateModification> changes) {
    final next = StateVersion(
      querySet: client.localState.querySetVersion,
      identity: identity,
      ts: encodeTs(++timestamp),
    );
    final result = client.receive(Transition(
      startVersion: version,
      endVersion: next,
      modifications: changes,
    ));
    version = next;
    expect(result.events.whereType<ReconnectRequiredEvent>(), isEmpty);
    return result;
  }

  void signIn() {
    client.markIdentityChange();
    client.setAuth(tokenType: 'User', token: 'alice');
    transition(1, [QueryUpdated(queryId: query.queryId, value: 'alice')]);
    client.drainOutgoing();
    client.takeIdentityChangeEvents();
  }

  void expectHidden() {
    expect(client.currentResultForQuery(query.queryId), isNull);
    expect(client.localResultForQuery('profile:me', {}), isNull);
    expect(client.cachedResultForQuery('profile:me', {}), isNull);
    expect(client.currentQueryEvent(query.queryId), isA<QueryLoadingEvent>());
  }
}

void main() {
  test(
      'sign-out invalidates a live subscription seeded only from the warm cache',
      () {
    final session = _Session()..signIn();
    final client = session.client;
    client.unsubscribe(session.query.subscriberId);
    session.transition(1, [QueryRemoved(queryId: session.query.queryId)]);
    final renewed = client.subscribe('profile:me', {});
    expect(client.optimisticResultForQuery('profile:me', {}), isNull);
    expect(client.cachedResultForQuery('profile:me', {}),
        isA<StoredQuerySuccess>());
    client.clearAuth();
    expect(
        client.takeIdentityChangeEvents().single,
        isA<QueryLoadingEvent>()
            .having((e) => e.queryId, 'queryId', renewed.queryId));
    expect(client.localResultForQuery('profile:me', {}), isNull);
  });

  test(
      'sign-out hides active results and ignores transitions of the old identity',
      () {
    final session = _Session()..signIn();
    final client = session.client;
    client.clearAuth();
    expect(client.takeIdentityChangeEvents().single, isA<QueryLoadingEvent>());
    session.expectHidden();
    session.transition(1,
        [QueryUpdated(queryId: session.query.queryId, value: 'alice secret')]);
    session.expectHidden();
    final result = session.transition(
        2, [QueryUpdated(queryId: session.query.queryId, value: null)]);
    expect(result.events.whereType<QueryUpdateEvent>().single.result,
        isA<StoredQuerySuccess>().having((r) => r.value, 'value', isNull));
  });

  test(
      'an unchanged public result becomes visible only after identity confirmation',
      () {
    final session = _Session()..signIn();
    session.client.clearAuth();
    session.expectHidden();
    final result = session.transition(2, []);
    expect(result.events.whereType<QueryUpdateEvent>().single.result,
        isA<StoredQuerySuccess>().having((r) => r.value, 'value', 'alice'));
  });

  test(
      'identity changes discard old optimistic layers rather than rebasing them on the next user',
      () {
    final session = _Session()..signIn();
    final client = session.client;
    var replays = 0;
    client.applyOptimisticUpdate((store) {
      replays++;
      store.setQuery('profile:me', {}, 'optimistic alice');
    }, 42);
    client.markIdentityChange();
    client.setAuth(tokenType: 'User', token: 'bob');
    session.expectHidden();
    session.transition(
        2, [QueryUpdated(queryId: session.query.queryId, value: 'bob')]);
    expect(replays, 1);
    expect(client.hasOptimisticUpdateForQuery('profile:me', {}), isFalse);
    expect(client.localResultForQuery('profile:me', {}),
        isA<StoredQuerySuccess>().having((r) => r.value, 'value', 'bob'));
  });

  test('a pending token fetch and superseded tokens cannot restore old results',
      () {
    final session = _Session()..signIn();
    final client = session.client;
    client.markIdentityChange();
    client.pause();
    session.transition(1, []);
    session.expectHidden();
    client.setAuth(tokenType: 'User', token: 'bob');
    // While paused, the old identity version remains current locally.
    session.transition(1, []);
    session.expectHidden();
    client.resume();
    client.markIdentityChange();
    client.setAuth(tokenType: 'User', token: 'carol');
    session.transition(
        2, [QueryUpdated(queryId: session.query.queryId, value: 'bob')]);
    session.expectHidden();
    session.transition(
        3, [QueryUpdated(queryId: session.query.queryId, value: 'carol')]);
    expect(client.localResultForQuery('profile:me', {}),
        isA<StoredQuerySuccess>().having((r) => r.value, 'value', 'carol'));
  });

  for (final signOut in <bool>[false, true]) {
    test(
        'identity confirmation survives version reset on reconnect (signOut: $signOut)',
        () {
      final session = _Session()..signIn();
      final client = session.client;
      client.markIdentityChange();
      if (signOut) {
        client.clearAuth();
      } else {
        client.setAuth(tokenType: 'User', token: 'bob');
      }
      client.prepareReconnect();
      session.version = const StateVersion.initial();
      session.expectHidden();
      session.transition(client.authVersion, [
        QueryUpdated(queryId: session.query.queryId, value: 'new identity')
      ]);
      expect(
          client.localResultForQuery('profile:me', {}),
          isA<StoredQuerySuccess>()
              .having((r) => r.value, 'value', 'new identity'));
    });
  }

  test('same-user token refresh and reconnect preserve live query results', () {
    final session = _Session()..signIn();
    final client = session.client;
    client.setAuth(tokenType: 'User', token: 'refreshed alice');
    expect(client.takeIdentityChangeEvents(), isEmpty);
    expect(client.localResultForQuery('profile:me', {}),
        isA<StoredQuerySuccess>());
    client.prepareReconnect();
    expect(client.localResultForQuery('profile:me', {}),
        isA<StoredQuerySuccess>());
  });
}
