import 'dart:io';

import 'package:dartvex_codegen/dartvex_codegen.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('DartGenerator', () {
    late FunctionsSpec spec;

    setUpAll(() async {
      final fixture =
          await File(
            path.join('test', 'fixtures', 'function_spec.json'),
          ).readAsString();
      spec = const SpecParser().parseString(fixture);
    });

    test('generates deterministic file tree and warnings', () {
      final output = DartGenerator().generate(spec);

      expect(output.files.keys.toList()..sort(), <String>[
        'api.dart',
        'modules/admin.dart',
        'modules/admin/users.dart',
        'modules/events.dart',
        'modules/kv.dart',
        'modules/messages.dart',
        'runtime.dart',
        'schema.dart',
      ]);
      expect(output.warnings, hasLength(4));
      expect(output.warnings, anyElement(contains('Skipping HTTP action')));
      expect(
        output.warnings,
        anyElement(contains('Unknown Convex type "quantum"')),
      );
      expect(output.warnings, anyElement(contains('cannot be represented')));
      expect(
        output.warnings,
        anyElement(
          allOf(
            contains('events.ts:dispatch'),
            contains('non-object top-level args'),
          ),
        ),
      );
      // The internal function's unknown "nebula" type is never generated, so
      // it must not produce a warning.
      expect(output.warnings, everyElement(isNot(contains('nebula'))));
    });

    test('emits the generated header and analyzer suppressions everywhere', () {
      final output = DartGenerator().generate(spec);

      for (final entry in output.files.entries) {
        expect(
          entry.value,
          startsWith('$generatedFileHeader\n$generatedFileIgnores\n'),
          reason: '${entry.key} must carry the header and ignore_for_file',
        );
      }
    });

    test('matches golden files for every emitted file', () async {
      final output = DartGenerator().generate(spec);
      final goldenRoot = path.join('test', 'goldens', 'sample');

      for (final entry in output.files.entries) {
        final golden = File(
          path.joinAll(<String>[goldenRoot, ...entry.key.split('/')]),
        );
        expect(
          golden.existsSync(),
          isTrue,
          reason: 'missing golden for ${entry.key}',
        );
        expect(entry.value, await golden.readAsString(), reason: entry.key);
      }

      final goldenFiles =
          Directory(goldenRoot)
              .listSync(recursive: true)
              .whereType<File>()
              .map(
                (file) => path.posix.joinAll(
                  path.split(path.relative(file.path, from: goldenRoot)),
                ),
              )
              .toSet();
      expect(
        goldenFiles,
        output.files.keys.toSet(),
        reason: 'stale golden files',
      );
    });

    test('generates runtime helpers and APIs aligned with runtime types', () {
      final output = DartGenerator().generate(spec);
      final runtime = output.files['runtime.dart']!;
      final api = output.files['api.dart']!;
      final messages = output.files['modules/messages.dart']!;
      final users = output.files['modules/admin/users.dart']!;

      expect(runtime, contains('BigInt expectBigInt'));
      expect(runtime, contains("Expected \${label ?? 'bigint'}"));
      expect(runtime, contains('class TypedQueryLoading<T>'));
      expect(runtime, contains('final Object? data;'));
      expect(runtime, contains('final List<String> logLines;'));
      expect(runtime, isNot(contains('base64Decode')));
      expect(runtime, isNot(contains('List<int>')));

      expect(api, contains('final ConvexFunctionCaller _client;'));
      expect(
        runtime,
        contains('QueryError(:final message, :final data, :final logLines)'),
      );
      expect(runtime, contains('QueryLoading(:final hasPendingWrites)'));
      expect(
        runtime,
        contains(
          'QuerySuccess(:final value, :final logLines, :final hasPendingWrites)',
        ),
      );
      expect(api, contains('typedQueryResult<HealthResult>('));
      expect(
        messages,
        contains("if (attachment.isDefined) 'attachment': attachment.value,"),
      );
      expect(
        users,
        contains('typedef SyncTypeResult = ({bool success, BigInt count});'),
      );
      expect(
        users,
        contains(
          "count: expectBigInt(map['count'], label: 'SyncTypeResultCount')",
        ),
      );
    });

    test('throws when function names generate duplicate methods', () {
      final collidingSpec = FunctionsSpec(
        url: 'https://sample.convex.cloud',
        functions: <BaseFunctionSpec>[
          _function(identifier: 'messages.ts:send-public'),
          _function(identifier: 'messages.ts:send_public'),
        ],
      );

      expect(
        () => DartGenerator().generate(collidingSpec),
        throwsA(
          isA<NamingException>().having(
            (error) => error.message,
            'message',
            contains('sendPublic'),
          ),
        ),
      );
    });

    test('throws when query subscription helper collides with function', () {
      final collidingSpec = FunctionsSpec(
        url: 'https://sample.convex.cloud',
        functions: <BaseFunctionSpec>[
          _function(identifier: 'messages.ts:list', functionType: 'Query'),
          _function(identifier: 'messages.ts:list-subscribe'),
        ],
      );

      expect(
        () => DartGenerator().generate(collidingSpec),
        throwsA(
          isA<NamingException>().having(
            (error) => error.message,
            'message',
            contains('listSubscribe'),
          ),
        ),
      );
    });

    test('throws when child module getter collides with function', () {
      final collidingSpec = FunctionsSpec(
        url: 'https://sample.convex.cloud',
        functions: <BaseFunctionSpec>[
          _function(identifier: 'index.ts:admin-users'),
          _function(identifier: 'admin_users.ts:list'),
        ],
      );

      expect(
        () => DartGenerator().generate(collidingSpec),
        throwsA(
          isA<NamingException>().having(
            (error) => error.message,
            'message',
            contains('adminUsers'),
          ),
        ),
      );
    });

    test('throws when table ID class names collide', () {
      final collidingSpec = FunctionsSpec(
        url: 'https://example.com',
        functions: <BaseFunctionSpec>[
          _function(
            identifier: 'users.ts:first',
            returns: const ConvexIdType('user-data'),
          ),
          _function(
            identifier: 'users.ts:second',
            returns: const ConvexIdType('user_data'),
          ),
        ],
      );

      expect(
        () => DartGenerator().generate(collidingSpec),
        throwsA(
          isA<NamingException>()
              .having(
                (error) => error.message,
                'message',
                contains('UserDataId'),
              )
              .having(
                (error) => error.message,
                'message',
                allOf(contains('user-data'), contains('user_data')),
              ),
        ),
      );
    });

    test('gives a system table a distinct ID class only on collision', () {
      final collidingSpec = FunctionsSpec(
        url: 'https://example.com',
        functions: <BaseFunctionSpec>[
          _function(
            identifier: 'files.ts:upload',
            returns: const ConvexIdType('_storage'),
          ),
          _function(
            identifier: 'files.ts:record',
            returns: const ConvexIdType('storage'),
          ),
        ],
      );

      final output = DartGenerator().generate(collidingSpec);
      final schema = output.files['schema.dart']!;
      final files = output.files['modules/files.dart']!;
      expect(schema, contains('class SystemStorageId extends ConvexTableId'));
      expect(schema, contains("tableName = '_storage'"));
      expect(schema, contains('class StorageId extends ConvexTableId'));
      expect(files, contains('Future<SystemStorageId> upload('));
      expect(files, contains('Future<StorageId> record('));

      // Without a user `storage` table, `_storage` keeps its short name.
      final storageOnly = DartGenerator().generate(
        FunctionsSpec(
          url: 'https://example.com',
          functions: <BaseFunctionSpec>[
            _function(
              identifier: 'files.ts:upload',
              returns: const ConvexIdType('_storage'),
            ),
          ],
        ),
      );
      expect(
        storageOnly.files['schema.dart'],
        allOf(
          contains('class StorageId extends ConvexTableId'),
          isNot(contains('SystemStorageId')),
        ),
      );
    });

    test('table collection does not reject an arg named like the result', () {
      // A `result` arg used to be pre-mapped as `<Fn>Result`, colliding with
      // the return type's typedef even though rendering names it
      // `<Fn>ArgsResult`.
      final output = DartGenerator().generate(
        FunctionsSpec(
          url: 'https://example.com',
          functions: <BaseFunctionSpec>[
            FunctionSpec(
              functionType: 'Mutation',
              args: const ConvexObjectType(<String, ConvexField>{
                'result': ConvexField(
                  fieldType: ConvexUnionType(<ConvexType>[
                    ConvexLiteralType('correct'),
                    ConvexLiteralType('wrong'),
                  ]),
                  optional: false,
                ),
              }),
              returns: const ConvexObjectType(<String, ConvexField>{
                'score': ConvexField(
                  fieldType: ConvexNumberType(),
                  optional: false,
                ),
              }),
              identifier: 'quiz.ts:submitAnswer',
              visibility: const Visibility('public'),
            ),
          ],
        ),
      );

      final quiz = output.files['modules/quiz.dart']!;
      expect(quiz, contains('typedef SubmitAnswerResult = ({double score});'));
      expect(quiz, contains('enum SubmitAnswerArgsResult {'));
    });

    test('maps non-object args validators to an untyped map argument', () {
      final output = DartGenerator().generate(
        FunctionsSpec(
          url: 'https://example.com',
          functions: <BaseFunctionSpec>[
            FunctionSpec(
              functionType: 'Query',
              args: const ConvexRecordType(
                keys: ConvexStringType(),
                values: ConvexField(
                  fieldType: ConvexNumberType(),
                  optional: false,
                ),
              ),
              returns: const ConvexNumberType(),
              identifier: 'stats.ts:sum',
              visibility: const Visibility('public'),
            ),
          ],
        ),
      );

      final stats = output.files['modules/stats.dart']!.replaceAll(
        RegExp(r'\s+'),
        ' ',
      );
      expect(
        stats,
        contains(
          'Future<double> sum([ Map<String, dynamic> args = '
          'const <String, dynamic>{}, ]) async',
        ),
      );
      expect(
        output.warnings,
        anyElement(
          allOf(contains('stats.ts:sum'), contains('non-object top-level')),
        ),
      );
    });

    test('generated mutations accept and forward an optimistic update', () {
      final output = DartGenerator().generate(spec);
      final messages = output.files['modules/messages.dart']!;
      final kv = output.files['modules/kv.dart']!;
      final events = output.files['modules/events.dart']!;

      expect(messages, contains('OptimisticUpdate? optimisticUpdate,'));
      expect(kv, contains('OptimisticUpdate? optimisticUpdate,'));
      expect(kv, contains('optimisticUpdate,\n    );'));
      // Untyped args keep their optional positional map.
      expect(
        events,
        contains(
          'dispatch([\n'
          '    Map<String, dynamic> args = const <String, dynamic>{},\n'
          '    OptimisticUpdate? optimisticUpdate,\n'
          '  ])',
        ),
      );
      // Queries and their subscriptions never take one.
      expect(
        RegExp('optimisticUpdate').allMatches(output.files['api.dart']!),
        isEmpty,
      );

      final colliding = DartGenerator().generate(
        FunctionsSpec(
          url: 'https://example.com',
          functions: <BaseFunctionSpec>[
            FunctionSpec(
              functionType: 'Mutation',
              args: const ConvexObjectType(<String, ConvexField>{
                'optimistic_update': ConvexField(
                  fieldType: ConvexBooleanType(),
                  optional: false,
                ),
              }),
              returns: const ConvexNullType(),
              identifier: 'flags.ts:set_flag',
              visibility: const Visibility('public'),
            ),
          ],
        ),
      );
      expect(
        colliding.files['modules/flags.dart'],
        isNot(contains('OptimisticUpdate?')),
      );
      expect(
        colliding.warnings,
        anyElement(
          allOf(contains('flags.ts:set_flag'), contains('optimisticUpdate')),
        ),
      );
    });

    test('maps colliding system fields and Object member names', () {
      final output = DartGenerator().generate(spec);
      final events = output.files['modules/events.dart']!;

      expect(events, contains('EventsId systemId,'));
      expect(events, contains('double systemCreationTime,'));
      expect(events, contains('String id,'));
      expect(events, contains('String toStringValue,'));
      expect(events, contains('BigInt ts,'));
      expect(events, contains('String callback,'));
      expect(events, contains('dynamic payload,'));
      expect(events, contains('required Map<String, double> scores'));
    });

    test('deduplicates union nested types even when args map twice', () {
      // Function args are mapped once as an object and once per field, so
      // union case-name claims must be stable across both passes.
      const payload = ConvexUnionType(<ConvexType>[
        ConvexObjectType(<String, ConvexField>{
          'kind': ConvexField(
            fieldType: ConvexLiteralType('choice'),
            optional: false,
          ),
          'value': ConvexField(
            fieldType: ConvexUnionType(<ConvexType>[
              ConvexLiteralType('a'),
              ConvexLiteralType('b'),
            ]),
            optional: false,
          ),
        }),
        ConvexObjectType(<String, ConvexField>{
          'kind': ConvexField(
            fieldType: ConvexLiteralType('text'),
            optional: false,
          ),
          'value': ConvexField(fieldType: ConvexStringType(), optional: false),
        }),
      ]);
      final output = DartGenerator().generate(
        FunctionsSpec(
          url: 'https://example.com',
          functions: <BaseFunctionSpec>[
            FunctionSpec(
              functionType: 'Mutation',
              args: const ConvexObjectType(<String, ConvexField>{
                'payload': ConvexField(fieldType: payload, optional: false),
              }),
              returns: const ConvexNullType(),
              identifier: 'forms.ts:save',
              visibility: const Visibility('public'),
            ),
          ],
        ),
      );

      final forms = output.files['modules/forms.dart']!;
      expect(forms, contains('class SaveArgsPayload1Value extends'));
      expect(forms, contains('enum SaveArgsPayload1Value2 {'));
    });

    test('escapes generated imports, function names, and table names', () {
      final specialSpec = FunctionsSpec(
        url: 'https://sample.convex.cloud',
        functions: <BaseFunctionSpec>[
          _function(
            identifier: r"weird$module's.ts:send$public",
            returns: const ConvexIdType(r"price$table's"),
          ),
        ],
      );

      final output = DartGenerator().generate(specialSpec);
      final api = output.files['api.dart']!;
      final module = output.files[r"modules/weird$module's.dart"]!;
      final schema = output.files['schema.dart']!;

      expect(api, contains(r"import './modules/weird\$module\'s.dart';"));
      expect(module, contains(r"'weird\$module\'s:send\$public'"));
      expect(
        schema,
        contains(r"static const String tableName = 'price\$table\'s';"),
      );
    });

    test('throws when module path segments are unsafe for file output', () {
      final unsafeSpec = FunctionsSpec(
        url: 'https://sample.convex.cloud',
        functions: <BaseFunctionSpec>[
          _function(identifier: '../escape.ts:list'),
        ],
      );

      expect(
        () => DartGenerator().generate(unsafeSpec),
        throwsA(
          isA<GenerationException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('Unsafe Convex module path segment ".."'),
              contains('../escape.ts:list'),
            ),
          ),
        ),
      );
    });

    test('throws when module path segments contain platform separators', () {
      final unsafeSpec = FunctionsSpec(
        url: 'https://sample.convex.cloud',
        functions: <BaseFunctionSpec>[
          _function(identifier: r'admin\users.ts:list'),
        ],
      );

      expect(
        () => DartGenerator().generate(unsafeSpec),
        throwsA(
          isA<GenerationException>().having(
            (error) => error.message,
            'message',
            contains(r'Unsafe Convex module path segment "admin\users"'),
          ),
        ),
      );
    });

    test('throws when generated Dart cannot be formatted', () {
      final invalidSpec = FunctionsSpec(
        url: 'https://example.com',
        functions: <BaseFunctionSpec>[
          _function(identifier: 'messages.ts:list'),
        ],
      );

      expect(
        () => DartGenerator(
          naming: const _InvalidMethodNaming(),
        ).generate(invalidSpec),
        throwsA(
          isA<GenerationException>().having(
            (error) => error.message,
            'message',
            contains('could not be formatted'),
          ),
        ),
      );
    });

    test(
      'surfaces parser warnings and degrades unknown types without throwing',
      () {
        final degradedSpec = const SpecParser().parseString('''
{
  "url": "https://sample.convex.cloud",
  "functions": [
    {
      "functionType": "Query",
      "args": { "type": "object", "value": {} },
      "returns": {
        "type": "object",
        "value": {
          "mystery": {
            "fieldType": { "type": "quantum" },
            "optional": false
          }
        }
      },
      "identifier": "messages.ts:future",
      "visibility": { "kind": "public" }
    }
  ]
}
''');

        final output = DartGenerator().generate(degradedSpec);

        expect(
          output.warnings,
          anyElement(
            allOf(
              contains('messages.ts:future'),
              contains('field "mystery"'),
              contains('Unknown Convex type "quantum"'),
            ),
          ),
        );
        // The unknown field degraded to a dynamic value rather than aborting.
        expect(output.files['modules/messages.dart'], contains('mystery'));
      },
    );

    test('generates typed and untyped paginated query bindings', () {
      final output = DartGenerator().generate(spec);
      final messages = output.files['modules/messages.dart']!;
      final runtime = output.files['runtime.dart']!;

      // The runtime template gains the generic typed-pagination wrappers.
      expect(runtime, contains('class TypedConvexPaginatedQuery<T>'));
      expect(runtime, contains('class TypedConvexPaginatedResult<T>'));

      // Typed paginated query: a generated element model, paginationOpts
      // stripped from the exposed API, and pageSize exposed.
      expect(
        messages,
        contains(
          'TypedConvexPaginatedQuery<PaginatePublicPageItem> paginatePublic({',
        ),
      );
      expect(messages, contains('typedef PaginatePublicPageItem ='));
      expect(messages, contains('_client.paginatedQuery('));
      expect(messages, contains("'messages:paginatePublic'"));
      expect(messages, contains('int pageSize = 20'));
      expect(messages, isNot(contains('paginationOpts')));

      // Non-paginationOpts args pass through.
      expect(
        messages,
        contains("if (channel.isDefined) 'channel': channel.value"),
      );

      // Returns-less paginated query degrades to untyped Map page items.
      expect(
        messages,
        contains(
          'TypedConvexPaginatedQuery<Map<String, dynamic>> paginateRaw({',
        ),
      );
      expect(
        messages,
        contains("expectMap(raw, label: 'PaginateRawPageItem')"),
      );
    });

    test('demotes a paginated query whose argument collides with pageSize', () {
      const paginationOpts = ConvexField(
        fieldType: ConvexObjectType(<String, ConvexField>{
          'numItems': ConvexField(
            fieldType: ConvexNumberType(),
            optional: false,
          ),
          'cursor': ConvexField(
            fieldType: ConvexUnionType(<ConvexType>[
              ConvexStringType(),
              ConvexNullType(),
            ]),
            optional: false,
          ),
        }),
        optional: false,
      );
      final collidingSpec = FunctionsSpec(
        url: 'https://sample.convex.cloud',
        functions: <BaseFunctionSpec>[
          FunctionSpec(
            functionType: 'Query',
            args: const ConvexObjectType(<String, ConvexField>{
              'paginationOpts': paginationOpts,
              'page_size': ConvexField(
                fieldType: ConvexNumberType(),
                optional: false,
              ),
            }),
            returns: const ConvexAnyType(),
            identifier: 'messages.ts:paginateOdd',
            visibility: const Visibility('public'),
          ),
        ],
      );

      final output = DartGenerator().generate(collidingSpec);
      final messages = output.files['modules/messages.dart']!;

      // The sanitized arg name page_size -> pageSize would be declared twice
      // in the paginated wrapper; the function demotes to a plain query
      // method (paginationOpts stays exposed) with a warning.
      expect(messages, isNot(contains('TypedConvexPaginatedQuery')));
      expect(messages, contains('Future<dynamic> paginateOdd({'));
      expect(messages, contains('paginateOddSubscribe'));
      expect(
        output.warnings,
        anyElement(
          allOf(contains('messages.ts:paginateOdd'), contains('pageSize')),
        ),
      );
    });

    test(
      'covers the full surface: number enum, unknown type, exotic literal',
      () {
        final output = DartGenerator().generate(spec);
        final users = output.files['modules/admin/users.dart']!;

        // A number-literal union becomes a typed enum.
        expect(users, contains('enum DiagnoseArgsLevel'));
        expect(users, contains('required DiagnoseArgsLevel level'));

        // An unknown type tag and an exotic ($integer-encoded) literal both
        // degrade to dynamic instead of crashing generation.
        expect(
          users,
          contains(
            'typedef DiagnoseResult = ({dynamic future, dynamic bigLiteral});',
          ),
        );
      },
    );
  });
}

class _InvalidMethodNaming extends Naming {
  const _InvalidMethodNaming();

  @override
  String methodName(String raw) => 'broken-name';
}

FunctionSpec _function({
  required String identifier,
  String functionType = 'Mutation',
  ConvexType returns = const ConvexStringType(),
}) {
  return FunctionSpec(
    functionType: functionType,
    args: const ConvexObjectType(<String, ConvexField>{}),
    returns: returns,
    identifier: identifier,
    visibility: const Visibility('public'),
  );
}
