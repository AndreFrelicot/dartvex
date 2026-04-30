import 'dart:typed_data';

import 'package:dartvex/dartvex.dart' as dartvex;
import 'package:dartvex/src/protocol/encoding.dart';
import 'package:dartvex/src/protocol/messages.dart';
import 'package:dartvex/src/protocol/state_version.dart';
import 'package:dartvex/src/values/json_codec.dart';
import 'package:test/test.dart';

void main() {
  group('Convex value codec', () {
    test('BigInt round-trips through Convex JSON encoding', () {
      final values = <BigInt>[
        BigInt.zero,
        BigInt.one,
        BigInt.from(-1),
        BigInt.parse('9223372036854775807'),
        BigInt.parse('-9223372036854775808'),
      ];

      for (final value in values) {
        final encoded = convexToJson(value);
        final decoded = jsonToConvex(encoded);

        expect(encoded, contains(r'$integer'));
        expect(decoded, value);
      }
    });

    test('convexInt64 helper encodes to Convex integer', () {
      final encoded = convexToJson(dartvex.convexInt64(42));
      final decoded = jsonToConvex(encoded);

      expect(encoded, contains(r'$integer'));
      expect(decoded, BigInt.from(42));
    });

    test('out-of-range BigInt throws', () {
      expect(
        () => convexToJson(BigInt.parse('9223372036854775808')),
        throwsArgumentError,
      );
      expect(
        () => convexToJson(BigInt.parse('-9223372036854775809')),
        throwsArgumentError,
      );
    });

    test('special doubles round-trip', () {
      final nan = jsonToConvex(convexToJson(double.nan)) as double;
      final positiveInfinity =
          jsonToConvex(convexToJson(double.infinity)) as double;
      final negativeInfinity =
          jsonToConvex(convexToJson(double.negativeInfinity)) as double;
      final negativeZero = jsonToConvex(convexToJson(-0.0)) as double;

      expect(nan.isNaN, isTrue);
      expect(positiveInfinity, double.infinity);
      expect(negativeInfinity, double.negativeInfinity);
      expect(negativeZero, 0.0);
      expect(negativeZero.isNegative, isTrue);
    });

    test('normal finite doubles stay plain JSON numbers', () {
      expect(convexToJson(42.5), 42.5);
      expect(convexToJson(3), 3);
    });

    test('plain int stays a JSON number', () {
      expect(convexToJson(42), 42);
    });

    test('Uint8List round-trips', () {
      final bytes = Uint8List.fromList(<int>[0, 1, 2, 255]);
      final decoded = jsonToConvex(convexToJson(bytes)) as Uint8List;

      expect(decoded, orderedEquals(bytes));
    });

    test('nested values round-trip', () {
      final encoded = convexToJson(<String, dynamic>{
        'count': BigInt.from(7),
        'special': -0.0,
        'bytes': Uint8List.fromList(<int>[7, 8, 9]),
        'items': <dynamic>[
          BigInt.from(-3),
          <String, dynamic>{'ok': true},
        ],
      }) as Map<String, dynamic>;

      final decoded = jsonToConvex(encoded) as Map<String, dynamic>;

      expect(decoded['count'], BigInt.from(7));
      expect((decoded['special'] as double).isNegative, isTrue);
      expect(decoded['bytes'], orderedEquals(<int>[7, 8, 9]));
      expect((decoded['items'] as List<dynamic>).first, BigInt.from(-3));
    });

    test('invalid field names throw', () {
      expect(
        () => convexToJson(<String, dynamic>{r'$bad': 1}),
        throwsArgumentError,
      );
      expect(
        () => convexToJson(<String, dynamic>{'bad\nkey': 1}),
        throwsArgumentError,
      );
    });

    test(r'decoding $set and $map throws', () {
      expect(
        () => jsonToConvex(<String, dynamic>{r'$set': const <dynamic>[]}),
        throwsFormatException,
      );
      expect(
        () => jsonToConvex(<String, dynamic>{r'$map': const <dynamic>[]}),
        throwsFormatException,
      );
    });
  });

  group('Convex protocol value integration', () {
    test('Transition decodes encoded values into Dart runtime types', () {
      final message = ServerMessage.fromJson(<String, dynamic>{
        'type': 'Transition',
        'startVersion': const StateVersion.initial().toJson(),
        'endVersion': StateVersion(
          querySet: 1,
          identity: 0,
          ts: encodeTs(1),
        ).toJson(),
        'modifications': <dynamic>[
          <String, dynamic>{
            'type': 'QueryUpdated',
            'queryId': 1,
            'value': <String, dynamic>{
              'count': convexToJson(BigInt.from(9)),
              'bytes': convexToJson(Uint8List.fromList(<int>[1, 2, 3])),
              'special': convexToJson(-0.0),
            },
            'logLines': const <dynamic>[],
          },
          <String, dynamic>{
            'type': 'QueryFailed',
            'queryId': 2,
            'errorMessage': 'boom',
            'errorData': <String, dynamic>{
              'code': convexToJson(BigInt.from(500)),
            },
            'logLines': const <dynamic>[],
          },
        ],
      }) as Transition;

      final updated = message.modifications.first as QueryUpdated;
      final updatedValue = updated.value as Map<String, dynamic>;
      final failed = message.modifications.last as QueryFailed;
      final failedData = failed.errorData as Map<String, dynamic>;

      expect(updatedValue['count'], BigInt.from(9));
      expect(updatedValue['bytes'], orderedEquals(<int>[1, 2, 3]));
      expect((updatedValue['special'] as double).isNegative, isTrue);
      expect(failedData['code'], BigInt.from(500));
    });

    test('MutationResponse and ActionResponse decode encoded result values',
        () {
      final mutation = MutationResponse.fromJson(<String, dynamic>{
        'type': 'MutationResponse',
        'requestId': 1,
        'success': true,
        'result': <String, dynamic>{
          'count': convexToJson(BigInt.from(2)),
        },
        'ts': encodeTs(2),
      });
      final action = ActionResponse.fromJson(<String, dynamic>{
        'type': 'ActionResponse',
        'requestId': 2,
        'success': true,
        'result': convexToJson(Uint8List.fromList(<int>[4, 5])),
      });

      expect(
          (mutation.result as Map<String, dynamic>)['count'], BigInt.from(2));
      expect(action.result, orderedEquals(<int>[4, 5]));
    });

    test('Add Mutation and Action encode special values in args', () {
      final args = <dynamic>[
        <String, dynamic>{
          'count': BigInt.from(42),
          'special': -0.0,
          'bytes': Uint8List.fromList(<int>[9, 8, 7]),
        },
      ];

      final addJson = Add(
        queryId: 1,
        udfPath: 'messages:list',
        args: args,
      ).toJson();
      final mutationJson = const Mutation(
        requestId: 1,
        udfPath: 'messages:send',
        args: <dynamic>[],
      );
      final actionJson = const Action(
        requestId: 2,
        udfPath: 'messages:act',
        args: <dynamic>[],
      );

      final mutationEncoded = Mutation(
        requestId: mutationJson.requestId,
        udfPath: mutationJson.udfPath,
        args: args,
      ).toJson();
      final actionEncoded = Action(
        requestId: actionJson.requestId,
        udfPath: actionJson.udfPath,
        args: args,
      ).toJson();

      final addArgs =
          (addJson['args'] as List<dynamic>).single as Map<String, dynamic>;
      final mutationArgs = (mutationEncoded['args'] as List<dynamic>).single
          as Map<String, dynamic>;
      final actionArgs = (actionEncoded['args'] as List<dynamic>).single
          as Map<String, dynamic>;

      for (final encodedArgs in <Map<String, dynamic>>[
        addArgs,
        mutationArgs,
        actionArgs,
      ]) {
        expect(encodedArgs['count'], contains(r'$integer'));
        expect(encodedArgs['special'], contains(r'$float'));
        expect(encodedArgs['bytes'], contains(r'$bytes'));
      }
    });
  });
}
