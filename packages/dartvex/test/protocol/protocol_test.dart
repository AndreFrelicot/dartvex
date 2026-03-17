import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:test/test.dart';

void main() {
  group('protocol encoding', () {
    test('timestamp round-trips', () {
      const input = 123456789;
      expect(decodeTs(encodeTs(input)), input);
    });

    test('state version ts comparison uses decoded timestamp', () {
      final older = StateVersion(
        querySet: 1,
        identity: 1,
        ts: encodeTs(1),
      );
      expect(older.isTsAtLeast(encodeTs(1)), isTrue);
      expect(older.isTsAtLeast(encodeTs(2)), isFalse);
    });
  });

  group('message serialization', () {
    final clientMessages = <ClientMessage>[
      Connect(
        sessionId: 'session-1',
        connectionCount: 2,
        lastCloseReason: 'Reconnect',
        maxObservedTimestamp: encodeTs(42),
        clientTs: 7,
      ),
      ModifyQuerySet(
        baseVersion: 0,
        newVersion: 1,
        modifications: const <QuerySetOperation>[
          Add(queryId: 1, udfPath: 'messages:list', args: <dynamic>[
            {'a': 1}
          ]),
          Remove(queryId: 2),
        ],
      ),
      const Mutation(
        requestId: 1,
        udfPath: 'messages:send',
        args: <dynamic>[
          {'body': 'hello'}
        ],
      ),
      const Action(
        requestId: 2,
        udfPath: 'messages:act',
        args: <dynamic>[
          {'body': 'hello'}
        ],
      ),
      const Authenticate(
        tokenType: 'User',
        baseVersion: 1,
        value: 'jwt-token',
      ),
      const Event(eventType: 'Pong', event: null),
    ];

    final serverMessages = <ServerMessage>[
      Transition(
        startVersion: const StateVersion.initial(),
        endVersion: StateVersion(querySet: 1, identity: 1, ts: encodeTs(1)),
        modifications: const <StateModification>[
          QueryUpdated(queryId: 1, value: {'ok': true}, logLines: <String>[]),
          QueryFailed(queryId: 2, errorMessage: 'boom'),
          QueryRemoved(queryId: 3),
        ],
      ),
      const TransitionChunk(
        chunk: 'YWJj',
        partNumber: 1,
        totalParts: 1,
        transitionId: 'transition-1',
      ),
      MutationResponse(
        requestId: 1,
        success: true,
        result: {'ok': true},
        ts: encodeTs(2),
        logLines: const <String>['done'],
      ),
      const ActionResponse(
        requestId: 2,
        success: false,
        errorMessage: 'act failed',
      ),
      const Ping(),
      const AuthError(error: 'bad token', baseVersion: 3),
      const FatalError(error: 'fatal'),
    ];

    for (final message in clientMessages) {
      test('${message.runtimeType} client round-trips', () {
        expect(
          ClientMessage.fromJson(message.toJson()).toJson(),
          message.toJson(),
        );
      });
    }

    for (final message in serverMessages) {
      test('${message.runtimeType} server round-trips', () {
        expect(
          ServerMessage.fromJson(message.toJson()).toJson(),
          message.toJson(),
        );
      });
    }

    test('Transition parses optional timing fields when present', () {
      final json = <String, dynamic>{
        'type': 'Transition',
        'startVersion': const StateVersion.initial().toJson(),
        'endVersion': StateVersion(
          querySet: 2,
          identity: 0,
          ts: encodeTs(1),
        ).toJson(),
        'modifications': const <dynamic>[],
        'serverTs': 1710000000000000000.0,
        'clientClockSkew': 150.5,
      };

      final message = ServerMessage.fromJson(json) as Transition;

      expect(message.serverTs, 1710000000000000000.0);
      expect(message.clientClockSkew, 150.5);
    });

    test('Transition handles missing optional timing fields', () {
      final json = <String, dynamic>{
        'type': 'Transition',
        'startVersion': const StateVersion.initial().toJson(),
        'endVersion': StateVersion(
          querySet: 2,
          identity: 0,
          ts: encodeTs(1),
        ).toJson(),
        'modifications': const <dynamic>[],
      };

      final message = ServerMessage.fromJson(json) as Transition;

      expect(message.serverTs, isNull);
      expect(message.clientClockSkew, isNull);
    });

    test('Transition toJson includes timing fields only when present', () {
      final withFields = Transition(
        startVersion: const StateVersion.initial(),
        endVersion: StateVersion(querySet: 2, identity: 0, ts: encodeTs(1)),
        modifications: const <StateModification>[],
        serverTs: 12345.0,
        clientClockSkew: 42.5,
      );

      expect(withFields.toJson()['serverTs'], 12345.0);
      expect(withFields.toJson()['clientClockSkew'], 42.5);

      final withoutFields = Transition(
        startVersion: const StateVersion.initial(),
        endVersion: StateVersion(querySet: 2, identity: 0, ts: encodeTs(1)),
        modifications: const <StateModification>[],
      );

      expect(withoutFields.toJson().containsKey('serverTs'), isFalse);
      expect(
        withoutFields.toJson().containsKey('clientClockSkew'),
        isFalse,
      );
    });
  });
}
