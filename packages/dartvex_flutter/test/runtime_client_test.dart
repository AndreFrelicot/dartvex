import 'dart:async';
import 'dart:convert';

import 'package:dartvex/dartvex.dart' as convex;
import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:dartvex_flutter/src/runtime_client.dart'
    show ConvexSeededSubscription;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConvexClientRuntime', () {
    test('seeds currentConnectionState from wrapped client', () async {
      final client = convex.ConvexClient(
        'https://demo.convex.cloud',
        config: const convex.ConvexClientConfig(connectImmediately: false),
      );
      final runtime = ConvexClientRuntime(client);

      expect(
        runtime.currentConnectionState,
        ConvexConnectionState.disconnected,
      );

      runtime.dispose();
      client.dispose();
    });

    test(
      'maps optimistic core query events to pending runtime snapshots',
      () async {
        final adapter = _MockWebSocketAdapter();
        final client = convex.ConvexClient(
          'https://example.com',
          config: convex.ConvexClientConfig(adapterFactory: (_) => adapter),
        );
        final runtime = ConvexClientRuntime(client);
        await _settle();

        final subscription = runtime.subscribe('messages:list');
        final events = <ConvexRuntimeQueryEvent>[];
        final listener = subscription.stream.listen(events.add);
        await _settle();

        final querySet = adapter.decodedSentMessages
            .where((message) => message['type'] == 'ModifyQuerySet')
            .last;
        final queryId =
            (((querySet['modifications'] as List<dynamic>).single
                    as Map<String, dynamic>)['queryId'])
                as int;

        adapter.pushServerMessage(<String, dynamic>{
          'type': 'Transition',
          'startVersion': _version(querySet: 0, ts: 'AAAAAAAAAAA='),
          'endVersion': _version(querySet: 1, ts: 'AQAAAAAAAAA='),
          'modifications': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'QueryUpdated',
              'queryId': queryId,
              'value': <String>['a'],
              'logLines': <String>['server-log'],
            },
          ],
        });
        await _settle();

        final remote = events.last as ConvexRuntimeQuerySuccess;
        expect(remote.source, ConvexQuerySource.remote);
        expect(remote.hasPendingWrites, isFalse);
        expect(remote.logLines, <String>['server-log']);

        final mutation = runtime.mutate(
          'messages:send',
          const <String, dynamic>{'body': 'b'},
          (store) {
            final list =
                (store.getQuery('messages:list') as List<dynamic>?) ??
                const <dynamic>[];
            store.setQuery(
              'messages:list',
              const <String, dynamic>{},
              <dynamic>[...list, 'b'],
            );
          },
        );
        await _settle();

        final optimistic = events.last as ConvexRuntimeQuerySuccess;
        expect(optimistic.value, <String>['a', 'b']);
        expect(optimistic.source, ConvexQuerySource.cache);
        expect(optimistic.hasPendingWrites, isTrue);

        final mutationMessage = adapter.decodedSentMessages
            .where((message) => message['type'] == 'Mutation')
            .last;
        adapter.pushServerMessage(<String, dynamic>{
          'type': 'MutationResponse',
          'requestId': mutationMessage['requestId'],
          'success': false,
          'errorMessage': 'rejected',
        });

        await expectLater(mutation, throwsA(isA<convex.ConvexException>()));
        await listener.cancel();
        subscription.cancel();
        runtime.dispose();
        client.dispose();
      },
    );

    test('wrappers of the same client are equal and hold no listener', () {
      final client = convex.ConvexClient(
        'https://demo.convex.cloud',
        config: const convex.ConvexClientConfig(connectImmediately: false),
      );
      final a = ConvexClientRuntime(client);
      final b = ConvexClientRuntime(client);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(ConvexClientRuntime(client, disposeClient: true)));
      expect(identical(a.client, client), isTrue);
      expect(identical(a.functionCaller, client), isTrue);
      // The connection state is read through, not cached by a listener.
      expect(a.currentConnectionState, client.currentConnectionState);

      a.dispose();
      b.dispose();
      client.dispose();
    });

    test(
      'a new subscription knows the live result of the same query',
      () async {
        final adapter = _MockWebSocketAdapter();
        final client = convex.ConvexClient(
          'https://example.com',
          config: convex.ConvexClientConfig(adapterFactory: (_) => adapter),
        );
        final runtime = ConvexClientRuntime(client);
        await _settle();

        final first = runtime.subscribe('messages:list', const {'c': 'a'});
        final listener = first.stream.listen((_) {});
        await _settle();
        expect((first as ConvexSeededSubscription).currentEvent, isNull);

        final querySet = adapter.decodedSentMessages
            .where((message) => message['type'] == 'ModifyQuerySet')
            .last;
        final queryId =
            (((querySet['modifications'] as List<dynamic>).single
                    as Map<String, dynamic>)['queryId'])
                as int;
        adapter.pushServerMessage(<String, dynamic>{
          'type': 'Transition',
          'startVersion': _version(querySet: 0, ts: 'AAAAAAAAAAA='),
          'endVersion': _version(querySet: 1, ts: 'AQAAAAAAAAA='),
          'modifications': <Map<String, dynamic>>[
            <String, dynamic>{
              'type': 'QueryUpdated',
              'queryId': queryId,
              'value': <String>['a'],
            },
          ],
        });
        await _settle();

        // Another wrapper of the same client shares the live results.
        final second = ConvexClientRuntime(
          client,
        ).subscribe('messages:list', const {'c': 'a'});
        final seed = (second as ConvexSeededSubscription).currentEvent;
        expect(seed, isA<ConvexRuntimeQuerySuccess>());
        expect((seed! as ConvexRuntimeQuerySuccess).value, <String>['a']);

        final otherArgs = runtime.subscribe('messages:list', const {'c': 'b'});
        expect((otherArgs as ConvexSeededSubscription).currentEvent, isNull);

        // Once every subscription is gone, nothing stale is kept.
        await listener.cancel();
        first.cancel();
        second.cancel();
        otherArgs.cancel();
        final third = runtime.subscribe('messages:list', const {'c': 'a'});
        expect((third as ConvexSeededSubscription).currentEvent, isNull);
        third.cancel();

        runtime.dispose();
        client.dispose();
      },
    );

    test('maps optimistic clear to runtime loading events', () async {
      final adapter = _MockWebSocketAdapter();
      final client = convex.ConvexClient(
        'https://example.com',
        config: convex.ConvexClientConfig(adapterFactory: (_) => adapter),
      );
      final runtime = ConvexClientRuntime(client);
      await _settle();

      final subscription = runtime.subscribe('messages:list');
      final events = <ConvexRuntimeQueryEvent>[];
      final listener = subscription.stream.listen(events.add);
      await _settle();

      final querySet = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .last;
      final queryId =
          (((querySet['modifications'] as List<dynamic>).single
                  as Map<String, dynamic>)['queryId'])
              as int;

      adapter.pushServerMessage(<String, dynamic>{
        'type': 'Transition',
        'startVersion': _version(querySet: 0, ts: 'AAAAAAAAAAA='),
        'endVersion': _version(querySet: 1, ts: 'AQAAAAAAAAA='),
        'modifications': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': 'QueryUpdated',
            'queryId': queryId,
            'value': <String>['a'],
          },
        ],
      });
      await _settle();
      expect(events.last, isA<ConvexRuntimeQuerySuccess>());

      final mutation = runtime.mutate(
        'messages:send',
        const <String, dynamic>{'body': 'b'},
        (store) => store.clearQuery('messages:list', const <String, dynamic>{}),
      );
      await _settle();

      final loading = events.last as ConvexRuntimeQueryLoading;
      expect(loading.source, ConvexQuerySource.cache);
      expect(loading.hasPendingWrites, isTrue);

      final mutationMessage = adapter.decodedSentMessages
          .where((message) => message['type'] == 'Mutation')
          .last;
      adapter.pushServerMessage(<String, dynamic>{
        'type': 'MutationResponse',
        'requestId': mutationMessage['requestId'],
        'success': false,
        'errorMessage': 'rejected',
      });

      await expectLater(mutation, throwsA(isA<convex.ConvexException>()));
      await listener.cancel();
      subscription.cancel();
      runtime.dispose();
      client.dispose();
    });
  });
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 10));

Map<String, dynamic> _version({required int querySet, required String ts}) {
  return <String, dynamic>{'querySet': querySet, 'identity': 0, 'ts': ts};
}

class _MockWebSocketAdapter implements convex.WebSocketAdapter {
  final StreamController<String> _messagesController =
      StreamController<String>.broadcast();
  final StreamController<convex.WebSocketCloseEvent> _closeController =
      StreamController<convex.WebSocketCloseEvent>.broadcast();

  final List<String> sentMessages = <String>[];
  final List<String> connectedUrls = <String>[];
  bool _connected = false;

  List<Map<String, dynamic>> get decodedSentMessages {
    return sentMessages
        .map((message) => jsonDecode(message) as Map<String, dynamic>)
        .toList(growable: false);
  }

  @override
  Future<void> connect(String url) async {
    connectedUrls.add(url);
    _connected = true;
  }

  @override
  void send(String message) {
    if (!_connected) {
      throw StateError('Mock socket is disconnected');
    }
    sentMessages.add(message);
  }

  void pushServerMessage(Map<String, dynamic> message) {
    _messagesController.add(jsonEncode(message));
  }

  @override
  Stream<String> get messages => _messagesController.stream;

  @override
  Stream<convex.WebSocketCloseEvent> get closeEvents => _closeController.stream;

  @override
  Future<void> close() async {
    _connected = false;
  }

  @override
  bool get isConnected => _connected;
}
