import 'dart:io';

import 'package:dartvex_codegen/dartvex_codegen.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('SpecParser', () {
    test('parses representative function-spec JSON', () async {
      final fixture =
          await File(
            path.join('test', 'fixtures', 'function_spec.json'),
          ).readAsString();
      final spec = const SpecParser().parseString(fixture);

      expect(spec.url, 'https://sample.convex.cloud');
      expect(spec.functions, hasLength(20));
      expect(
        spec.publicFunctions.map((function) => function.identifier),
        containsAll(<String>[
          'messages.ts:list',
          'messages.ts:send',
          'admin/users.ts:sync',
          'index.ts:health',
        ]),
      );

      final listMessages = spec.publicFunctions.firstWhere(
        (function) => function.identifier == 'messages.ts:list',
      );
      expect(listMessages.modulePathSegments, <String>['messages']);
      expect(listMessages.args, isA<ConvexObjectType>());
      expect(listMessages.returns, isA<ConvexArrayType>());

      final httpAction = spec.functions.last;
      expect(httpAction, isA<HttpFunctionSpec>());
    });

    test('throws on malformed JSON roots', () {
      expect(
        () => const SpecParser().parseString('[]'),
        throwsA(isA<SpecParserException>()),
      );
    });

    test('throws when required fields are missing', () {
      expect(
        () => const SpecParser().parseMap(<String, dynamic>{
          'url': 'https://sample.convex.cloud',
          'functions': <dynamic>[
            <String, dynamic>{'functionType': 'Query'},
          ],
        }),
        throwsA(isA<SpecParserException>()),
      );
    });

    test('treats missing or null args and returns as ConvexAnyType', () {
      final spec = const SpecParser().parseMap(<String, dynamic>{
        'url': 'https://sample.convex.cloud',
        'functions': <dynamic>[
          // Explicit nulls, as emitted by `convex function-spec` for a
          // function declared without a returns validator.
          <String, dynamic>{
            'functionType': 'Query',
            'args': null,
            'returns': null,
            'identifier': 'messages.ts:ping',
            'visibility': <String, dynamic>{'kind': 'public'},
          },
          // The args/returns keys omitted entirely.
          <String, dynamic>{
            'functionType': 'Mutation',
            'identifier': 'messages.ts:pong',
            'visibility': <String, dynamic>{'kind': 'public'},
          },
        ],
      });

      final ping = spec.publicFunctions.firstWhere(
        (function) => function.identifier == 'messages.ts:ping',
      );
      expect(ping.args, isA<ConvexAnyType>());
      expect(ping.returns, isA<ConvexAnyType>());

      final pong = spec.publicFunctions.firstWhere(
        (function) => function.identifier == 'messages.ts:pong',
      );
      expect(pong.args, isA<ConvexAnyType>());
      expect(pong.returns, isA<ConvexAnyType>());
    });

    test('names the offending function and field path in parse errors', () {
      expect(
        () => const SpecParser().parseMap(<String, dynamic>{
          'url': 'https://sample.convex.cloud',
          'functions': <dynamic>[
            <String, dynamic>{
              'functionType': 'Query',
              'args': <String, dynamic>{
                'type': 'object',
                'value': <String, dynamic>{
                  'filters': 'this should be an object',
                },
              },
              'identifier': 'messages.ts:list',
              'visibility': <String, dynamic>{'kind': 'public'},
            },
          ],
        }),
        throwsA(
          isA<SpecParserException>().having(
            (error) => error.message,
            'message',
            allOf(contains('messages.ts:list'), contains('field "filters"')),
          ),
        ),
      );
    });

    test('prefixes the function identifier onto structural errors', () {
      expect(
        () => const SpecParser().parseMap(<String, dynamic>{
          'url': 'https://sample.convex.cloud',
          'functions': <dynamic>[
            <String, dynamic>{
              'functionType': 'Mutation',
              'args': null,
              'returns': null,
              'identifier': 'messages.ts:send',
              // Wrong shape: visibility must be an object with a "kind".
              'visibility': 'public',
            },
          ],
        }),
        throwsA(
          isA<SpecParserException>().having(
            (error) => error.message,
            'message',
            contains('messages.ts:send'),
          ),
        ),
      );
    });

    test('degrades an unknown Convex type to any with a warning', () {
      final spec = const SpecParser().parseMap(<String, dynamic>{
        'url': 'https://sample.convex.cloud',
        'functions': <dynamic>[
          <String, dynamic>{
            'functionType': 'Query',
            'args': <String, dynamic>{
              'type': 'object',
              'value': <String, dynamic>{},
            },
            'returns': <String, dynamic>{'type': 'quantum'},
            'identifier': 'messages.ts:future',
            'visibility': <String, dynamic>{'kind': 'public'},
          },
        ],
      });

      final future = spec.publicFunctions.single;
      expect(future.returns, isA<ConvexAnyType>());
      expect(
        spec.warnings,
        anyElement(
          allOf(
            contains('messages.ts:future'),
            contains('Unknown Convex type "quantum"'),
          ),
        ),
      );
    });

    test('parses the convex 1.43+/1.49 commitTs and function types', () {
      final spec = const SpecParser().parseMap(<String, dynamic>{
        'url': 'https://sample.convex.cloud',
        'functions': <dynamic>[
          <String, dynamic>{
            'functionType': 'Query',
            'args': <String, dynamic>{
              'type': 'object',
              'value': <String, dynamic>{
                'bare': <String, dynamic>{
                  'fieldType': <String, dynamic>{'type': 'function'},
                  'optional': true,
                },
              },
            },
            'returns': <String, dynamic>{
              'type': 'object',
              'value': <String, dynamic>{
                'ts': <String, dynamic>{
                  'fieldType': <String, dynamic>{'type': 'commitTs'},
                  'optional': false,
                },
                'onDone': <String, dynamic>{
                  'fieldType': <String, dynamic>{
                    'type': 'function',
                    'fnType': 'mutation',
                    'args': <String, dynamic>{
                      'type': 'object',
                      'value': <String, dynamic>{
                        'id': <String, dynamic>{
                          'fieldType': <String, dynamic>{
                            'type': 'id',
                            'tableName': 'jobs',
                          },
                          'optional': false,
                        },
                      },
                    },
                    'returns': <String, dynamic>{'type': 'null'},
                  },
                  'optional': false,
                },
              },
            },
            'identifier': 'jobs.ts:status',
            'visibility': <String, dynamic>{'kind': 'public'},
          },
        ],
      });

      expect(spec.warnings, isEmpty);
      final function = spec.publicFunctions.single;
      final returns = function.returns as ConvexObjectType;
      expect(returns.value['ts']!.fieldType, isA<ConvexCommitTsType>());
      final onDone = returns.value['onDone']!.fieldType;
      expect(
        onDone,
        isA<ConvexFunctionHandleType>()
            .having((type) => type.fnType, 'fnType', 'mutation')
            .having((type) => type.args, 'args', isA<ConvexObjectType>())
            .having((type) => type.returns, 'returns', isA<ConvexNullType>()),
      );
      final bare =
          (function.args as ConvexObjectType).value['bare']!.fieldType
              as ConvexFunctionHandleType;
      expect(bare.fnType, isNull);
      expect(bare.args, isNull);
      expect(bare.returns, isNull);
    });

    test('only reports degraded types for public functions', () {
      Map<String, dynamic> function(String identifier, String visibility) =>
          <String, dynamic>{
            'functionType': 'Mutation',
            'args': <String, dynamic>{'type': 'object', 'value': {}},
            'returns': <String, dynamic>{'type': 'quantum'},
            'identifier': identifier,
            'visibility': <String, dynamic>{'kind': visibility},
          };
      final spec = const SpecParser().parseMap(<String, dynamic>{
        'url': 'https://sample.convex.cloud',
        'functions': <dynamic>[
          function('jobs.ts:internalCallback', 'internal'),
          function('jobs.ts:publicCallback', 'public'),
        ],
      });

      expect(spec.warnings, hasLength(1));
      expect(spec.warnings.single, contains('jobs.ts:publicCallback'));
    });

    test('extracts the spec from noisy package-runner output', () {
      final spec = const SpecParser().parseString(
        'yarn run v1.22.22\n'
        r'$ convex function-spec'
        '\n'
        '{"url": "https://sample.convex.cloud", "functions": []}\n'
        'Done in 2.01s.\n',
      );
      expect(spec.url, 'https://sample.convex.cloud');
      expect(spec.functions, isEmpty);

      expect(
        () => const SpecParser().parseString(''),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => const SpecParser().parseString('{"url": "https://x", "functi'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
