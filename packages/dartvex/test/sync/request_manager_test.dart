import 'dart:async';

import 'package:dartvex/src/exceptions.dart';
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/sync/request_manager.dart';
import 'package:test/test.dart';

void main() {
  group('RequestManager.hasSyncedPastLastReconnect', () {
    Mutation mutation(int requestId) => Mutation(
          requestId: requestId,
          udfPath: 'messages:send',
          args: const <dynamic>[],
        );
    Action action(int requestId) => Action(
          requestId: requestId,
          udfPath: 'messages:notify',
          args: const <dynamic>[],
        );

    test('starts synced with no requests', () {
      final manager = RequestManager();
      expect(manager.hasSyncedPastLastReconnect(), isTrue);
    });

    test('mutation: unsynced after restart until the transition catches up',
        () async {
      final manager = RequestManager();
      final future = manager.trackMutation(mutation(0), sent: true);

      // A response arrives but is held for read-your-writes. No restart yet.
      manager.handleMutationResponse(
        MutationResponse(
          requestId: 0,
          success: true,
          result: 'ok',
          ts: encodeTs(4),
        ),
      );
      expect(manager.hasSyncedPastLastReconnect(), isTrue);

      // Reconnect re-requests the still-pending mutation.
      final replay = manager.prepareReconnect();
      expect(replay.single, isA<Mutation>());
      expect(manager.hasSyncedPastLastReconnect(), isFalse);

      // A duplicate response does not resolve it on its own.
      manager.handleMutationResponse(
        MutationResponse(
          requestId: 0,
          success: true,
          result: 'duplicate',
          ts: encodeTs(4),
        ),
      );
      expect(manager.hasSyncedPastLastReconnect(), isFalse);

      // Transitioning past the mutation timestamp resolves it.
      manager.resolveMutationsUpTo(encodeTs(5));
      expect(manager.hasSyncedPastLastReconnect(), isTrue);
      expect(await future, 'ok');
    });

    test('sent actions are dropped on restart; unsent actions stay outstanding',
        () async {
      final manager = RequestManager();
      final sentFuture = manager.trackAction(action(0), sent: true);
      final unsentFuture = manager.trackAction(action(1), sent: false);
      final sentExpectation =
          expectLater(sentFuture, throwsA(isA<ConvexException>()));

      // Only the unsent action is replayed, and it is outstanding since the
      // restart.
      final replay = manager.prepareReconnect();
      expect(replay.single, isA<Action>());
      expect((replay.single as Action).requestId, 1);
      expect(manager.hasSyncedPastLastReconnect(), isFalse);

      await sentExpectation;

      // Its response clears the outstanding entry.
      manager.handleActionResponse(
        const ActionResponse(requestId: 1, success: true, result: 'done'),
      );
      expect(manager.hasSyncedPastLastReconnect(), isTrue);
      expect(await unsentFuture, 'done');
    });

    test('a failed mutation response clears the outstanding entry', () async {
      final manager = RequestManager();
      final future = manager.trackMutation(mutation(0), sent: true);
      unawaited(future.catchError((Object _) => null));

      manager.prepareReconnect();
      expect(manager.hasSyncedPastLastReconnect(), isFalse);

      manager.handleMutationResponse(
        const MutationResponse(
          requestId: 0,
          success: false,
          errorMessage: 'boom',
        ),
      );
      expect(manager.hasSyncedPastLastReconnect(), isTrue);
    });

    test('cancelling a request clears the outstanding entry', () async {
      final manager = RequestManager();
      final future = manager.trackMutation(mutation(0), sent: true);
      unawaited(future.catchError((Object _) => null));

      manager.prepareReconnect();
      expect(manager.hasSyncedPastLastReconnect(), isFalse);

      manager.cancelMutation(0, TimeoutException('timed out'));
      expect(manager.hasSyncedPastLastReconnect(), isTrue);
    });

    test('failAll clears the outstanding entries', () {
      final manager = RequestManager();
      final future = manager.trackMutation(mutation(0), sent: true);
      unawaited(future.catchError((Object _) => null));

      manager.prepareReconnect();
      expect(manager.hasSyncedPastLastReconnect(), isFalse);

      manager.failAll('ConvexClient has been disposed');
      expect(manager.hasSyncedPastLastReconnect(), isTrue);
    });

    test('an actionless, mutationless restart stays synced', () {
      final manager = RequestManager();
      manager.prepareReconnect();
      expect(manager.hasSyncedPastLastReconnect(), isTrue);
    });
  });

  group('RequestManager optimistic drop signals', () {
    Mutation mutation(int requestId) => Mutation(
          requestId: requestId,
          udfPath: 'messages:send',
          args: const <dynamic>[],
        );

    test('a failed mutation reports its id for an immediate rollback', () {
      final manager = RequestManager();
      final future = manager.trackMutation(mutation(0), sent: true);
      unawaited(future.catchError((Object _) => null));

      final dropped = manager.handleMutationResponse(
        const MutationResponse(
          requestId: 0,
          success: false,
          errorMessage: 'boom',
        ),
      );
      expect(dropped, <int>[0]);
    });

    test('a ts-less success reports its id immediately', () async {
      final manager = RequestManager();
      final future = manager.trackMutation(mutation(0), sent: true);

      final dropped = manager.handleMutationResponse(
        const MutationResponse(requestId: 0, success: true, result: 'ok'),
      );
      expect(dropped, <int>[0]);
      expect(await future, 'ok');
    });

    test('a parked success reports nothing until its transition lands', () {
      final manager = RequestManager();
      manager.trackMutation(mutation(0), sent: true);

      final dropped = manager.handleMutationResponseWithAppliedTransition(
        MutationResponse(
          requestId: 0,
          success: true,
          result: 'ok',
          ts: encodeTs(5),
        ),
        appliedTransitionTs: encodeTs(1),
      );
      expect(dropped, isEmpty);

      // The transition carrying the ts both resolves the mutation and surfaces
      // its id so the optimistic layer can be dropped.
      expect(manager.resolveMutationsUpTo(encodeTs(5)), <int>[0]);
    });

    test('a success whose transition already applied reports its id now', () {
      final manager = RequestManager();
      manager.trackMutation(mutation(0), sent: true);

      final dropped = manager.handleMutationResponseWithAppliedTransition(
        MutationResponse(
          requestId: 0,
          success: true,
          result: 'ok',
          ts: encodeTs(3),
        ),
        appliedTransitionTs: encodeTs(5),
      );
      expect(dropped, <int>[0]);
    });
  });

  group('RequestManager inflight metrics', () {
    Mutation mutation(int requestId) => Mutation(
          requestId: requestId,
          udfPath: 'messages:send',
          args: const <dynamic>[],
        );
    Action action(int requestId) => Action(
          requestId: requestId,
          udfPath: 'messages:notify',
          args: const <dynamic>[],
        );

    test('starts with nothing in flight', () {
      final manager = RequestManager();
      expect(manager.inflightMutations, 0);
      expect(manager.inflightActions, 0);
      expect(manager.hasInflightRequests, isFalse);
      expect(manager.timeOfOldestInflightRequest(), isNull);
    });

    test('counts tracked mutations and actions', () {
      final manager = RequestManager();
      final before = DateTime.now();
      manager.trackMutation(mutation(0), sent: true);
      manager.trackMutation(mutation(1), sent: true);
      manager.trackAction(action(2), sent: true);
      final after = DateTime.now();

      expect(manager.inflightMutations, 2);
      expect(manager.inflightActions, 1);
      expect(manager.hasInflightRequests, isTrue);
      final oldest = manager.timeOfOldestInflightRequest();
      expect(oldest, isNotNull);
      expect(oldest!.isBefore(before), isFalse);
      expect(oldest.isAfter(after), isFalse);
    });

    test('resolving requests decrements the counts', () async {
      final manager = RequestManager();
      final mutationFuture = manager.trackMutation(mutation(0), sent: true);
      final actionFuture = manager.trackAction(action(1), sent: true);
      expect(manager.inflightMutations, 1);
      expect(manager.inflightActions, 1);

      manager.handleMutationResponse(
        const MutationResponse(requestId: 0, success: true, result: 'ok'),
      );
      manager.handleActionResponse(
        const ActionResponse(requestId: 1, success: true, result: 'done'),
      );

      expect(manager.inflightMutations, 0);
      expect(manager.inflightActions, 0);
      expect(manager.hasInflightRequests, isFalse);
      expect(manager.timeOfOldestInflightRequest(), isNull);
      expect(await mutationFuture, 'ok');
      expect(await actionFuture, 'done');
    });

    test(
        'a mutation awaiting its transition still counts and reports now when '
        'it is the only inflight request', () {
      final manager = RequestManager();
      manager.trackMutation(mutation(0), sent: true);
      final beforeParkedOnly = DateTime.now();

      // Parked for read-your-writes: completed on the server, awaiting the
      // transition that carries its ts.
      manager.handleMutationResponseWithAppliedTransition(
        MutationResponse(
          requestId: 0,
          success: true,
          result: 'ok',
          ts: encodeTs(9),
        ),
        appliedTransitionTs: encodeTs(1),
      );

      // Still in flight by count. The official client reports the current time
      // when every in-flight request is already parked behind a transition.
      expect(manager.inflightMutations, 1);
      expect(manager.hasInflightRequests, isTrue);
      final parkedOldest = manager.timeOfOldestInflightRequest();
      expect(parkedOldest, isNotNull);
      expect(parkedOldest!.isBefore(beforeParkedOnly), isFalse);
      expect(parkedOldest.isAfter(DateTime.now()), isFalse);

      // A genuinely pending action becomes the oldest waiting request.
      manager.trackAction(action(1), sent: true);
      expect(manager.inflightActions, 1);
      expect(manager.timeOfOldestInflightRequest(), isNotNull);
    });
  });
}
