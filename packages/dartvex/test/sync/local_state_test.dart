import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:dartvex/src/sync/local_state.dart';
import 'package:test/test.dart';

void main() {
  group('LocalSyncState.hasSyncedPastLastReconnect', () {
    Transition transitionUpdating(List<int> queryIds) {
      return Transition(
        startVersion: const StateVersion.initial(),
        endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
        modifications: <StateModification>[
          for (final queryId in queryIds)
            QueryUpdated(
              queryId: queryId,
              value: const <String, dynamic>{'value': 1},
            ),
        ],
      );
    }

    test('a fresh state is already synced', () {
      final state = LocalSyncState();
      expect(state.hasSyncedPastLastReconnect(), isTrue);
    });

    test('restarting without outstanding queries stays synced', () {
      final state = LocalSyncState();
      state.prepareReconnect(<int>{});
      expect(state.hasSyncedPastLastReconnect(), isTrue);
    });

    test('subscribing alone does not flip the flag', () {
      final state = LocalSyncState();
      state.subscribe('hello:world', const <String, dynamic>{});
      expect(state.hasSyncedPastLastReconnect(), isTrue);
    });

    test('restart stays unsynced until every query is confirmed', () {
      final state = LocalSyncState();
      final queryId1 =
          state.subscribe('hello:world1', const <String, dynamic>{}).queryId;
      final queryId2 =
          state.subscribe('hello:world2', const <String, dynamic>{}).queryId;

      // Restart before any results arrive.
      state.prepareReconnect(<int>{});
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      // A partial result keeps the flag false.
      state.transition(transitionUpdating(<int>[queryId1]));
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      // The final result flips the flag true.
      state.transition(transitionUpdating(<int>[queryId2]));
      expect(state.hasSyncedPastLastReconnect(), isTrue);
    });

    test('queries with a prior remote result are not outstanding', () {
      final state = LocalSyncState();
      final queryId1 =
          state.subscribe('hello:world1', const <String, dynamic>{}).queryId;
      final queryId2 =
          state.subscribe('hello:world2', const <String, dynamic>{}).queryId;

      // queryId1 already held a result before the reconnect, so only queryId2
      // is outstanding after the restart.
      state.prepareReconnect(<int>{queryId1});
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      state.transition(transitionUpdating(<int>[queryId2]));
      expect(state.hasSyncedPastLastReconnect(), isTrue);
    });

    test('QueryFailed and QueryRemoved also clear outstanding queries', () {
      final state = LocalSyncState();
      final queryId1 =
          state.subscribe('hello:world1', const <String, dynamic>{}).queryId;
      final queryId2 =
          state.subscribe('hello:world2', const <String, dynamic>{}).queryId;
      state.prepareReconnect(<int>{});
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      state.transition(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryFailed(queryId: queryId1, errorMessage: 'boom'),
            QueryRemoved(queryId: queryId2),
          ],
        ),
      );
      expect(state.hasSyncedPastLastReconnect(), isTrue);
    });

    test('unsubscribing an outstanding query resyncs', () {
      final state = LocalSyncState();
      final registration =
          state.subscribe('hello:world', const <String, dynamic>{});
      state.prepareReconnect(<int>{});
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      state.unsubscribe(registration.subscriberId);
      expect(state.hasSyncedPastLastReconnect(), isTrue);
    });

    test('markAuthCompletion resolves outstanding auth', () {
      final state = LocalSyncState();
      state.setAuth(tokenType: 'User', value: 'token-123');
      expect(state.hasSyncedPastLastReconnect(), isTrue);

      state.prepareReconnect(<int>{});
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      state.markAuthCompletion();
      expect(state.hasSyncedPastLastReconnect(), isTrue);
    });

    test('clearing auth resolves outstanding auth', () {
      final state = LocalSyncState();
      state.setAuth(tokenType: 'User', value: 'token-123');
      state.prepareReconnect(<int>{});
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      state.setAuth(tokenType: 'None');
      expect(state.hasSyncedPastLastReconnect(), isTrue);
    });

    test('queries and auth must both be confirmed to resync', () {
      final state = LocalSyncState();
      final queryId =
          state.subscribe('hello:world', const <String, dynamic>{}).queryId;
      state.setAuth(tokenType: 'User', value: 'token-123');
      state.prepareReconnect(<int>{});
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      // Confirming the query is not enough while auth is outstanding.
      state.transition(transitionUpdating(<int>[queryId]));
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      // Confirming auth completes the resync.
      state.markAuthCompletion();
      expect(state.hasSyncedPastLastReconnect(), isTrue);
    });

    test('a restart without auth does not mark auth outstanding', () {
      final state = LocalSyncState();
      final queryId =
          state.subscribe('hello:world', const <String, dynamic>{}).queryId;
      state.prepareReconnect(<int>{});
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      // With no auth, confirming the query alone resyncs.
      state.transition(transitionUpdating(<int>[queryId]));
      expect(state.hasSyncedPastLastReconnect(), isTrue);
    });
  });
}
