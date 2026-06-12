import 'dart:async';

import 'package:dartvex/dartvex.dart';
import 'package:test/test.dart';

import 'test_helpers/mock_web_socket_adapter.dart';

/// The zero timestamp (8 zero bytes), at or below the initial applied
/// transition ts, so a successful mutation response resolves immediately
/// instead of parking for read-your-writes.
const String _zeroTs = 'AAAAAAAAAAA=';

void main() {
  group('eager argument validation', () {
    Future<void> settle() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    Future<void> waitUntil(
      bool Function() condition,
      String description, {
      Duration timeout = const Duration(seconds: 1),
    }) async {
      final stopwatch = Stopwatch()..start();
      while (!condition()) {
        if (stopwatch.elapsed >= timeout) {
          fail('Timed out waiting for $description');
        }
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }

    (ConvexClient, MockWebSocketAdapter) makeClient() {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          connectImmediately: false,
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      return (client, adapter);
    }

    test(
        'mutate with an unsupported arg type rejects immediately and leaves '
        'the connection untouched', () async {
      final (client, adapter) = makeClient();
      addTearDown(client.close);
      final subscription = client.subscribe('messages:list');
      addTearDown(subscription.cancel);
      await settle();
      expect(adapter.isConnected, isTrue);
      final framesBefore = adapter.sentMessages.length;

      await expectLater(
        client.mutate(
          'messages:send',
          <String, dynamic>{'when': DateTime.now()},
        ),
        throwsArgumentError,
      );
      await settle();

      // The poison mutation never reached the wire, the socket stayed open,
      // and no reconnect was triggered.
      expect(adapter.isConnected, isTrue);
      expect(adapter.sentMessages.length, framesBefore);
      expect(adapter.connectedUrls.length, 1);
    });

    test('action with a reserved-dollar field rejects immediately', () async {
      final (client, adapter) = makeClient();
      addTearDown(client.close);

      await expectLater(
        client.action('messages:notify', <String, dynamic>{r'$meta': 1}),
        throwsArgumentError,
      );
      await settle();
      // The lazy client never even needed to start the socket for it.
      expect(adapter.sentMessages, isEmpty);
    });

    test('a valid mutation still completes after a rejected one', () async {
      final (client, adapter) = makeClient();
      addTearDown(client.close);
      final subscription = client.subscribe('messages:list');
      addTearDown(subscription.cancel);
      await settle();

      await expectLater(
        client.mutate('messages:send', <String, dynamic>{'bad': Object()}),
        throwsArgumentError,
      );

      final future = client.mutate(
        'messages:send',
        <String, dynamic>{'body': 'hi'},
      );
      await settle();
      final mutationFrame = adapter.decodedSentMessages
          .lastWhere((message) => message['type'] == 'Mutation');
      adapter.pushServerMessage(<String, dynamic>{
        'type': 'MutationResponse',
        'requestId': mutationFrame['requestId'],
        'success': true,
        'result': 42,
        'ts': _zeroTs,
        'logLines': <String>[],
      });
      expect(await future, 42);
    });

    test('mutation args are deep-snapshotted at call time', () async {
      final (client, adapter) = makeClient();
      addTearDown(client.close);
      final subscription = client.subscribe('messages:list');
      addTearDown(subscription.cancel);
      await settle();

      final tags = <String>['a'];
      final future = client.mutate(
        'messages:send',
        <String, dynamic>{'tags': tags},
      );
      // Mutating the caller's nested list after the call must not change what
      // goes on the wire (the flush only runs in a later microtask).
      tags.add('b');
      await settle();

      final mutationFrame = adapter.decodedSentMessages
          .lastWhere((message) => message['type'] == 'Mutation');
      final sentArgs = (mutationFrame['args'] as List<dynamic>).single
          as Map<String, dynamic>;
      expect(sentArgs['tags'], <String>['a']);

      adapter.pushServerMessage(<String, dynamic>{
        'type': 'MutationResponse',
        'requestId': mutationFrame['requestId'],
        'success': true,
        'result': null,
        'ts': _zeroTs,
        'logLines': <String>[],
      });
      await future;
    });

    test('subscribe with an unsupported arg value throws synchronously', () {
      final (client, _) = makeClient();
      addTearDown(client.close);
      expect(
        () => client.subscribe(
          'messages:list',
          <String, dynamic>{'when': DateTime.now()},
        ),
        throwsArgumentError,
      );
    });

    test('reconnect replays the subscribe-time args snapshot', () async {
      final (client, adapter) = makeClient();
      addTearDown(client.close);
      final filter = <String>['a'];
      final subscription = client.subscribe(
        'messages:list',
        <String, dynamic>{'filter': filter},
      );
      addTearDown(subscription.cancel);
      await settle();

      // Mutate the caller's args after subscribing, then force a reconnect:
      // the replayed Add must carry the subscribe-time snapshot.
      filter.add('b');
      adapter.disconnect();
      await waitUntil(
        () => adapter.connectedUrls.length >= 2,
        'query replay reconnect',
      );
      expect(adapter.connectedUrls.length, 2);

      await waitUntil(
        () =>
            adapter.decodedSentMessages
                .where((message) => message['type'] == 'ModifyQuerySet')
                .expand((message) => message['modifications'] as List<dynamic>)
                .cast<Map<String, dynamic>>()
                .where((modification) => modification['type'] == 'Add')
                .length >=
            2,
        'query replay Add messages',
      );
      final adds = adapter.decodedSentMessages
          .where((message) => message['type'] == 'ModifyQuerySet')
          .expand((message) => message['modifications'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .where((modification) => modification['type'] == 'Add')
          .toList();
      expect(adds, hasLength(2));
      for (final add in adds) {
        final args =
            (add['args'] as List<dynamic>).single as Map<String, dynamic>;
        expect(args['filter'], <String>['a']);
      }
    });
  });
}
