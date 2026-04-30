import 'dart:async';

import 'package:dartvex/dartvex.dart';
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:test/test.dart';

import 'test_helpers/mock_web_socket_adapter.dart';

void main() {
  group('one-shot queries', () {
    Future<void> settle() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

    test('returns first result with correct generic type', () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final future = client.queryOnce<String>('config:get');
      await settle();

      final querySet = adapter.decodedSentMessages
          .where((m) => m['type'] == 'ModifyQuerySet')
          .last;
      final queryId = (((querySet['modifications'] as List<dynamic>).last
          as Map<String, dynamic>)['queryId']) as int;

      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryUpdated(queryId: queryId, value: 'hello'),
          ],
        ).toJson(),
      );

      final result = await future;
      expect(result, isA<String>());
      expect(result, 'hello');
      client.dispose();
    });

    test('query propagates errors as ConvexException with data and log lines',
        () async {
      final adapter = MockWebSocketAdapter();
      final client = ConvexClient(
        'https://demo.convex.cloud',
        config: ConvexClientConfig(
          adapterFactory: (_) => adapter,
          reconnectBackoff: const <Duration>[Duration.zero],
        ),
      );
      await settle();

      final future = client.query('config:get');
      await settle();

      final querySet = adapter.decodedSentMessages
          .where((m) => m['type'] == 'ModifyQuerySet')
          .last;
      final queryId = (((querySet['modifications'] as List<dynamic>).last
          as Map<String, dynamic>)['queryId']) as int;

      adapter.pushServerMessage(
        Transition(
          startVersion: const StateVersion.initial(),
          endVersion: StateVersion(querySet: 1, identity: 0, ts: encodeTs(1)),
          modifications: <StateModification>[
            QueryFailed(
              queryId: queryId,
              errorMessage: 'not found',
              errorData: const <String, dynamic>{'code': 'missing'},
              logLines: const <String>['server log'],
            ),
          ],
        ).toJson(),
      );

      await expectLater(
        future,
        throwsA(
          isA<ConvexException>()
              .having((error) => error.message, 'message', 'not found')
              .having(
            (error) => error.data,
            'data',
            const <String, dynamic>{'code': 'missing'},
          ).having(
            (error) => error.logLines,
            'logLines',
            const <String>['server log'],
          ),
        ),
      );
      client.dispose();
    });
  });
}
