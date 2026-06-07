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
      state.prepareReconnect();
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
      state.prepareReconnect();
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      // A partial result keeps the flag false.
      state.transition(transitionUpdating(<int>[queryId1]));
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      // The final result flips the flag true.
      state.transition(transitionUpdating(<int>[queryId2]));
      expect(state.hasSyncedPastLastReconnect(), isTrue);
    });

    test('queries with a prior remote result stay outstanding', () {
      final state = LocalSyncState();
      final queryId1 =
          state.subscribe('hello:world1', const <String, dynamic>{}).queryId;
      final queryId2 =
          state.subscribe('hello:world2', const <String, dynamic>{}).queryId;

      // queryId1 already held a result before the reconnect, but the server
      // still has to re-confirm it before the restart is considered synced.
      state.prepareReconnect();
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      state.transition(transitionUpdating(<int>[queryId2]));
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      state.transition(transitionUpdating(<int>[queryId1]));
      expect(state.hasSyncedPastLastReconnect(), isTrue);
    });

    test('QueryFailed and QueryRemoved also clear outstanding queries', () {
      final state = LocalSyncState();
      final queryId1 =
          state.subscribe('hello:world1', const <String, dynamic>{}).queryId;
      final queryId2 =
          state.subscribe('hello:world2', const <String, dynamic>{}).queryId;
      state.prepareReconnect();
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
      state.prepareReconnect();
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      state.unsubscribe(registration.subscriberId);
      expect(state.hasSyncedPastLastReconnect(), isTrue);
    });

    test('markAuthCompletion resolves outstanding auth', () {
      final state = LocalSyncState();
      state.setAuth(tokenType: 'User', value: 'token-123');
      expect(state.hasSyncedPastLastReconnect(), isTrue);

      state.prepareReconnect();
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      state.markAuthCompletion();
      expect(state.hasSyncedPastLastReconnect(), isTrue);
    });

    test('clearing auth resolves outstanding auth', () {
      final state = LocalSyncState();
      state.setAuth(tokenType: 'User', value: 'token-123');
      state.prepareReconnect();
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      state.setAuth(tokenType: 'None');
      expect(state.hasSyncedPastLastReconnect(), isTrue);
    });

    test('queries and auth must both be confirmed to resync', () {
      final state = LocalSyncState();
      final queryId =
          state.subscribe('hello:world', const <String, dynamic>{}).queryId;
      state.setAuth(tokenType: 'User', value: 'token-123');
      state.prepareReconnect();
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
      state.prepareReconnect();
      expect(state.hasSyncedPastLastReconnect(), isFalse);

      // With no auth, confirming the query alone resyncs.
      state.transition(transitionUpdating(<int>[queryId]));
      expect(state.hasSyncedPastLastReconnect(), isTrue);
    });
  });

  group('LocalSyncState pause/resume', () {
    test('subscriptions are buffered while paused and replayed on resume', () {
      final state = LocalSyncState();
      state.pause();
      expect(state.isPaused, isTrue);

      final registration =
          state.subscribe('messages:list', const <String, dynamic>{});
      // Nothing is emitted while paused, and the query-set version is untouched.
      expect(registration.message, isNull);
      expect(state.querySetVersion, 0);

      final (querySet, authenticate) = state.resume();
      expect(state.isPaused, isFalse);
      expect(authenticate, isNull);
      expect(querySet, isNotNull);
      expect(querySet!.baseVersion, 0);
      expect(querySet.newVersion, 1);
      final modification = querySet.modifications.single;
      expect(modification, isA<Add>());
      expect((modification as Add).queryId, registration.queryId);
    });

    test('auth set while paused defers the identity version until resume', () {
      final state = LocalSyncState();
      state.pause();
      state.setAuth(tokenType: 'User', value: 'tok');
      // Identity version does not advance until the auth is actually emitted.
      expect(state.authVersion, 0);

      final (querySet, authenticate) = state.resume();
      expect(querySet, isNull);
      expect(authenticate, isNotNull);
      expect(authenticate!.tokenType, 'User');
      expect(authenticate.value, 'tok');
      expect(authenticate.baseVersion, 0);
      expect(state.authVersion, 1);
    });

    test('auth clear while paused is emitted on resume', () {
      final state = LocalSyncState();
      state.setAuth(tokenType: 'User', value: 'tok');
      expect(state.authVersion, 1);

      state.pause();
      state.setAuth(tokenType: 'None');
      state.setAuth(tokenType: 'None');
      expect(state.authVersion, 1);

      final (querySet, authenticate) = state.resume();
      expect(querySet, isNull);
      expect(authenticate, isNotNull);
      expect(authenticate!.tokenType, 'None');
      expect(authenticate.baseVersion, 1);
      expect(state.authVersion, 2);
    });

    test('unsubscribing while paused cancels a buffered subscription', () {
      final state = LocalSyncState();
      state.pause();
      final registration =
          state.subscribe('messages:list', const <String, dynamic>{});
      state.unsubscribe(registration.subscriberId);

      final (querySet, authenticate) = state.resume();
      // The buffered Add was cancelled by the unsubscribe, so nothing is sent.
      expect(querySet, isNull);
      expect(authenticate, isNull);
    });

    test('resume re-affirms existing auth with no buffered queries', () {
      final state = LocalSyncState();
      state.setAuth(tokenType: 'User', value: 'tok'); // authVersion -> 1
      state.pause();

      final (querySet, authenticate) = state.resume();
      expect(querySet, isNull);
      expect(authenticate, isNotNull);
      expect(authenticate!.baseVersion, 1);
      expect(state.authVersion, 2);
    });

    test('prepareReconnect clears a pending pause', () {
      final state = LocalSyncState();
      state.pause();
      state.subscribe('messages:list', const <String, dynamic>{});
      state.prepareReconnect();
      expect(state.isPaused, isFalse);
      // A subsequent resume is a no-op.
      expect(state.resume(), equals((null, null)));
    });
  });

  group('LocalSyncState.isCurrentOrNewerAuthVersion', () {
    test('accepts the current and newer versions and rejects older ones', () {
      final state = LocalSyncState();
      // Identity version starts at 0.
      expect(state.isCurrentOrNewerAuthVersion(0), isTrue);
      expect(state.isCurrentOrNewerAuthVersion(1), isTrue);

      state.setAuth(tokenType: 'User', value: 'a'); // authVersion -> 1
      state.setAuth(tokenType: 'User', value: 'b'); // authVersion -> 2
      expect(state.isCurrentOrNewerAuthVersion(2), isTrue);
      expect(state.isCurrentOrNewerAuthVersion(3), isTrue);
      // A message reflecting the superseded version 1 is stale.
      expect(state.isCurrentOrNewerAuthVersion(1), isFalse);
    });
  });

  group('LocalSyncState.setAdminAuth', () {
    const impersonating = <String, dynamic>{'subject': 'user_123'};

    test('produces an Admin Authenticate carrying the impersonation', () {
      final state = LocalSyncState();
      final auth = state.setAdminAuth(
        value: 'admin-key',
        impersonating: impersonating,
      );

      expect(auth.tokenType, 'Admin');
      expect(auth.value, 'admin-key');
      expect(auth.impersonating, impersonating);
      expect(auth.baseVersion, 0);
      expect(state.authVersion, 1);
      expect(state.hasAuth, isTrue);

      // The wire form includes the impersonation attributes.
      final json = auth.toJson();
      expect(json['tokenType'], 'Admin');
      expect(json['impersonating'], impersonating);
    });

    test('re-emits Admin auth with impersonation on reconnect', () {
      final state = LocalSyncState();
      state.setAdminAuth(value: 'admin-key', impersonating: impersonating);

      final messages = state.prepareReconnect();
      final authenticate = messages.whereType<Authenticate>().single;
      expect(authenticate.tokenType, 'Admin');
      expect(authenticate.value, 'admin-key');
      expect(authenticate.impersonating, impersonating);
    });

    test('admin auth without impersonation omits the field on the wire', () {
      final state = LocalSyncState();
      final auth = state.setAdminAuth(value: 'admin-key');

      expect(auth.impersonating, isNull);
      expect(auth.toJson().containsKey('impersonating'), isFalse);
    });
  });
}
