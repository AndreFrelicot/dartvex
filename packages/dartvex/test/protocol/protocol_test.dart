import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:test/test.dart';

void main() {
  group('protocol encoding', () {
    test('timestamp round-trips', () {
      const input = 123456789;
      expect(decodeTs(encodeTs(input)), BigInt.from(input));
    });

    test('timestamp encoding handles full u64 values without ByteData uint64',
        () {
      final input = (BigInt.one << 63) + BigInt.from(42);
      expect(decodeTs(encodeTsBigInt(input)), input);
      expect(compareEncodedTs(encodeTsBigInt(input), encodeTs(42)),
          greaterThan(0));
    });

    test('timestamp decoding rejects malformed byte lengths', () {
      expect(() => decodeTs('AA=='), throwsFormatException);
      expect(
          () => compareEncodedTs(encodeTs(1), 'AA=='), throwsFormatException);
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
      const AuthError(
        error: 'bad token',
        baseVersion: 3,
        authUpdateAttempted: true,
      ),
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

    test('Add Mutation and Action round-trip componentPath', () {
      const componentPath = 'components/admin';

      final addJson = Add(
        queryId: 1,
        udfPath: 'messages:list',
        args: const <dynamic>[
          {'channel': 'general'},
        ],
        componentPath: componentPath,
      ).toJson();
      final mutationJson = Mutation(
        requestId: 2,
        udfPath: 'messages:send',
        args: const <dynamic>[
          {'body': 'hello'},
        ],
        componentPath: componentPath,
      ).toJson();
      final actionJson = Action(
        requestId: 3,
        udfPath: 'messages:act',
        args: const <dynamic>[
          {'body': 'hello'},
        ],
        componentPath: componentPath,
      ).toJson();

      final add = QuerySetOperation.fromJson(addJson) as Add;
      final mutation = ClientMessage.fromJson(mutationJson) as Mutation;
      final action = ClientMessage.fromJson(actionJson) as Action;

      expect(add.componentPath, componentPath);
      expect(mutation.componentPath, componentPath);
      expect(action.componentPath, componentPath);
      expect(add.toJson(), addJson);
      expect(mutation.toJson(), mutationJson);
      expect(action.toJson(), actionJson);
    });

    test('Authenticate round-trips impersonating identity attributes', () {
      final json = const Authenticate(
        tokenType: 'Admin',
        baseVersion: 4,
        value: 'admin-key',
        impersonating: <String, dynamic>{
          'subject': 'user-123',
          'issuer': 'https://issuer.example',
          'name': 'Admin User',
        },
      ).toJson();

      final message = ClientMessage.fromJson(json) as Authenticate;

      expect(message.impersonating, <String, dynamic>{
        'subject': 'user-123',
        'issuer': 'https://issuer.example',
        'name': 'Admin User',
      });
      expect(message.toJson(), json);
    });

    test('MutationResponse success requires a server timestamp on the wire',
        () {
      expect(
        () => ServerMessage.fromJson(const <String, dynamic>{
          'type': 'MutationResponse',
          'requestId': 1,
          'success': true,
          'result': 'ok',
          'logLines': <String>[],
        }),
        throwsFormatException,
      );
      expect(
        () => const MutationResponse(
          requestId: 1,
          success: true,
          result: 'ok',
        ).toJson(),
        throwsStateError,
      );
    });

    test('MutationResponse failure ignores a server timestamp on the wire', () {
      // The official runtime parser never validates a failure's `ts`; dartvex
      // matches it by dropping any unexpected value instead of rejecting.
      final decoded = ServerMessage.fromJson(<String, dynamic>{
        'type': 'MutationResponse',
        'requestId': 1,
        'success': false,
        'result': 'boom',
        'ts': encodeTs(1),
        'logLines': const <String>[],
      });
      expect(decoded, isA<MutationResponse>());
      expect((decoded as MutationResponse).success, isFalse);
      expect(decoded.ts, isNull);
      expect(
        MutationResponse(
          requestId: 1,
          success: false,
          errorMessage: 'boom',
          ts: encodeTs(1),
        ).toJson(),
        isNot(contains('ts')),
      );
    });

    test('AuthError tolerates a missing authUpdateAttempted on the wire', () {
      // The official client treats a missing `authUpdateAttempted` as not
      // explicitly false (it never rejects the message); dartvex decodes it to
      // `null` so a backend that omits the field still drives a reauth.
      final decoded = ServerMessage.fromJson(const <String, dynamic>{
        'type': 'AuthError',
        'error': 'bad token',
        'baseVersion': 3,
      });
      expect(decoded, isA<AuthError>());
      expect((decoded as AuthError).authUpdateAttempted, isNull);
      expect(decoded.toJson(), isNot(contains('authUpdateAttempted')));
      expect(
        const AuthError(
          error: 'bad token',
          baseVersion: 3,
          authUpdateAttempted: false,
        ).toJson(),
        const <String, dynamic>{
          'type': 'AuthError',
          'error': 'bad token',
          'baseVersion': 3,
          'authUpdateAttempted': false,
        },
      );
    });

    test('new optional protocol fields are omitted when unset', () {
      expect(
        const Connect(
          sessionId: 'session-1',
          connectionCount: 0,
          lastCloseReason: null,
          clientTs: 7,
        ).toJson(),
        <String, dynamic>{
          'type': 'Connect',
          'sessionId': 'session-1',
          'connectionCount': 0,
          'lastCloseReason': null,
          'clientTs': 7,
        },
      );
      expect(
        Add(
          queryId: 1,
          udfPath: 'messages:list',
          args: const <dynamic>[],
        ).toJson(),
        <String, dynamic>{
          'type': 'Add',
          'queryId': 1,
          'udfPath': 'messages:list',
          'args': const <dynamic>[],
          'journal': null,
        },
      );
      expect(
        const Mutation(
          requestId: 2,
          udfPath: 'messages:send',
          args: <dynamic>[],
        ).toJson(),
        <String, dynamic>{
          'type': 'Mutation',
          'requestId': 2,
          'udfPath': 'messages:send',
          'args': const <dynamic>[],
        },
      );
      expect(
        const Action(
          requestId: 3,
          udfPath: 'messages:act',
          args: <dynamic>[],
        ).toJson(),
        <String, dynamic>{
          'type': 'Action',
          'requestId': 3,
          'udfPath': 'messages:act',
          'args': const <dynamic>[],
        },
      );
      expect(
        const Authenticate(
          tokenType: 'User',
          baseVersion: 5,
          value: 'jwt-token',
        ).toJson(),
        <String, dynamic>{
          'type': 'Authenticate',
          'tokenType': 'User',
          'baseVersion': 5,
          'value': 'jwt-token',
        },
      );
    });
  });
}
