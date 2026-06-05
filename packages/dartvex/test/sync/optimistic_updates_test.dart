import 'package:dartvex/src/sync/local_state.dart';
import 'package:dartvex/src/sync/optimistic_updates.dart';
import 'package:dartvex/src/sync/remote_query_set.dart';
import 'package:test/test.dart';

void main() {
  group('OptimisticQueryResults', () {
    String token(String name,
        [Map<String, dynamic> args = const <String, dynamic>{}]) {
      return LocalSyncState.serializeQueryToken(
        LocalSyncState.canonicalizeUdfPath(name),
        args,
      );
    }

    OverlayServerQuery serverQuery(
      String name,
      Object? value, [
      Map<String, dynamic> args = const <String, dynamic>{},
    ]) {
      return (
        result: value == null
            ? null
            : StoredQuerySuccess(value: value, logLines: const <String>[]),
        udfPath: LocalSyncState.canonicalizeUdfPath(name),
        args: args,
      );
    }

    Object? valueAt(OptimisticQueryResults results, String tok) {
      final result = results.rawResultForToken(tok);
      return result is StoredQuerySuccess ? result.value : null;
    }

    test('server results are returned back if no optimistic updates exist', () {
      final results = OptimisticQueryResults();
      final changed = results.ingestQueryResultsFromServer(
        <String, OverlayServerQuery>{
          token('query1'): serverQuery('query1', 'query1 result'),
          token('query2'): serverQuery('query2', 'query2 result'),
        },
        <int>{},
      );

      expect(changed, <String>[token('query1'), token('query2')]);
      expect(valueAt(results, token('query1')), 'query1 result');
      expect(valueAt(results, token('query2')), 'query2 result');
    });

    test('an error result is overlaid but read back as null by an update', () {
      final results = OptimisticQueryResults();
      final changed = results.ingestQueryResultsFromServer(
        <String, OverlayServerQuery>{
          token('query'): (
            result: const StoredQueryError(
              message: 'Server Error',
              logLines: <String>[],
            ),
            udfPath: LocalSyncState.canonicalizeUdfPath('query'),
            args: const <String, dynamic>{},
          ),
        },
        <int>{},
      );
      expect(changed, <String>[token('query')]);
      expect(
          results.rawResultForToken(token('query')), isA<StoredQueryError>());

      Object? readBack = 'unset';
      results.applyOptimisticUpdate((store) {
        readBack = store.getQuery('query');
      }, 0);
      expect(readBack, isNull);
    });

    test('optimistic updates edit, replay on new server data, and drop', () {
      final results = OptimisticQueryResults();
      Map<String, OverlayServerQuery> serverResults(int value) {
        return <String, OverlayServerQuery>{
          token('query'): serverQuery('query', value)
        };
      }

      results.ingestQueryResultsFromServer(serverResults(100), <int>{});
      expect(valueAt(results, token('query')), 100);

      // Apply an update that increments the value.
      final changed = results.applyOptimisticUpdate((store) {
        final old = store.getQuery('query') as int;
        store.setQuery('query', const <String, dynamic>{}, old + 1);
      }, 0);
      expect(changed, <String>[token('query')]);
      expect(valueAt(results, token('query')), 101);

      // Fresh server data while the update is pending: it replays on top.
      results.ingestQueryResultsFromServer(serverResults(200), <int>{});
      expect(valueAt(results, token('query')), 201);

      // Dropping the update reverts to the server value.
      results.ingestQueryResultsFromServer(serverResults(300), <int>{0});
      expect(valueAt(results, token('query')), 300);
      expect(results.hasActiveUpdates, isFalse);
    });

    test('optimistic updates only report changed queries', () {
      final results = OptimisticQueryResults();
      results.ingestQueryResultsFromServer(
        <String, OverlayServerQuery>{
          token('query1'): serverQuery('query1', 'query1 result'),
          token('query2'): serverQuery('query2', 'query2 result'),
        },
        <int>{},
      );

      final changed = results.applyOptimisticUpdate((store) {
        store.setQuery(
            'query1', const <String, dynamic>{}, 'new query1 result');
      }, 0);

      expect(changed, <String>[token('query1')]);
      expect(valueAt(results, token('query1')), 'new query1 result');
      expect(valueAt(results, token('query2')), 'query2 result');
    });

    test('optimistic updates stack and drop independently', () {
      final results = OptimisticQueryResults();
      final server = <String, OverlayServerQuery>{
        token('query'): serverQuery('query', 2),
      };
      results.ingestQueryResultsFromServer(server, <int>{});
      expect(valueAt(results, token('query')), 2);

      results.applyOptimisticUpdate((store) {
        store.setQuery(
          'query',
          const <String, dynamic>{},
          (store.getQuery('query') as int) + 1,
        );
      }, 0);
      expect(valueAt(results, token('query')), 3);

      results.applyOptimisticUpdate((store) {
        store.setQuery(
          'query',
          const <String, dynamic>{},
          (store.getQuery('query') as int) * 2,
        );
      }, 1);
      expect(valueAt(results, token('query')), 6);

      // Drop the first update; only the doubling remains.
      results.ingestQueryResultsFromServer(server, <int>{0});
      expect(valueAt(results, token('query')), 4);

      // Drop the second update; back to the server value.
      results.ingestQueryResultsFromServer(server, <int>{1});
      expect(valueAt(results, token('query')), 2);
    });

    test('setQuery can write a successful Convex null value', () {
      final results = OptimisticQueryResults();
      results.ingestQueryResultsFromServer(
        <String, OverlayServerQuery>{
          token('query'): serverQuery('query', 'query value'),
        },
        <int>{},
      );
      expect(valueAt(results, token('query')), 'query value');

      results.applyOptimisticUpdate((store) {
        store.setQuery('query', const <String, dynamic>{}, null);
      }, 0);

      final result = results.rawResultForToken(token('query'));
      expect(result, isA<StoredQuerySuccess>());
      expect((result! as StoredQuerySuccess).value, isNull);
    });

    test('clearQuery marks a query as loading', () {
      final results = OptimisticQueryResults();
      results.ingestQueryResultsFromServer(
        <String, OverlayServerQuery>{
          token('query'): serverQuery('query', 'query value'),
        },
        <int>{},
      );
      expect(valueAt(results, token('query')), 'query value');

      results.applyOptimisticUpdate((store) {
        store.clearQuery('query', const <String, dynamic>{});
      }, 0);

      expect(results.rawResultForToken(token('query')), isNull);
      expect(results.isLoadingForToken(token('query')), isTrue);
    });

    test('getAllQueries returns every query of a given name', () {
      final results = OptimisticQueryResults();
      results.ingestQueryResultsFromServer(
        <String, OverlayServerQuery>{
          token('messages:list', <String, dynamic>{'channel': 'a'}):
              serverQuery('messages:list', <String>['a1'],
                  <String, dynamic>{'channel': 'a'}),
          token('messages:list', <String, dynamic>{'channel': 'b'}):
              serverQuery('messages:list', <String>['b1'],
                  <String, dynamic>{'channel': 'b'}),
          token('other:query'): serverQuery('other:query', 'x'),
        },
        <int>{},
      );

      List<OptimisticQueryEntry> all = const <OptimisticQueryEntry>[];
      results.applyOptimisticUpdate((store) {
        all = store.getAllQueries('messages:list');
      }, 0);

      expect(all, hasLength(2));
      expect(
        all.map((entry) => entry.args['channel']).toSet(),
        <String>{'a', 'b'},
      );
      expect(
          all.map((entry) => entry.value), everyElement(isA<List<dynamic>>()));
    });

    test('getQuery returns null for a query not in the client', () {
      final results = OptimisticQueryResults();
      Object? readBack = 'unset';
      results.applyOptimisticUpdate((store) {
        readBack = store.getQuery('missing:query');
      }, 0);
      expect(readBack, isNull);
    });

    test('apply-time failures do not leave active optimistic layers', () {
      final results = OptimisticQueryResults();
      final server = <String, OverlayServerQuery>{
        token('query'): serverQuery('query', 1),
      };
      results.ingestQueryResultsFromServer(server, <int>{});

      expect(
        () => results.applyOptimisticUpdate((_) {
          throw StateError('bad optimistic update');
        }, 0),
        throwsStateError,
      );
      expect(results.hasActiveUpdates, isFalse);

      results.ingestQueryResultsFromServer(
        <String, OverlayServerQuery>{token('query'): serverQuery('query', 2)},
        <int>{},
      );
      expect(valueAt(results, token('query')), 2);
    });

    test('replay-time failures drop only the failing optimistic layer', () {
      final results = OptimisticQueryResults();
      Map<String, OverlayServerQuery> serverResults(int value) {
        return <String, OverlayServerQuery>{
          token('query'): serverQuery('query', value),
        };
      }

      results.ingestQueryResultsFromServer(serverResults(1), <int>{});
      var poisonRuns = 0;
      results.applyOptimisticUpdate((store) {
        poisonRuns += 1;
        if (poisonRuns > 1) {
          throw StateError('poisoned replay');
        }
        store.setQuery('query', const <String, dynamic>{}, 'poison');
      }, 0);
      results.applyOptimisticUpdate((store) {
        store.setQuery('query', const <String, dynamic>{}, 'safe');
      }, 1);

      results.ingestQueryResultsFromServer(serverResults(2), <int>{});
      expect(valueAt(results, token('query')), 'safe');
      expect(results.hasActiveUpdates, isTrue);

      results.ingestQueryResultsFromServer(serverResults(3), <int>{1});
      expect(results.hasActiveUpdates, isFalse);
      expect(valueAt(results, token('query')), 3);
    });
  });
}
