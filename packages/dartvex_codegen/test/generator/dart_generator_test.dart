import 'dart:io';

import 'package:dartvex_codegen/dartvex_codegen.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('DartGenerator', () {
    late FunctionsSpec spec;

    setUpAll(() async {
      final fixture = await File(
        path.join('test', 'fixtures', 'function_spec.json'),
      ).readAsString();
      spec = const SpecParser().parseString(fixture);
    });

    test('generates deterministic file tree and warnings', () {
      final output = DartGenerator().generate(spec);

      expect(
        output.files.keys.toList()..sort(),
        <String>[
          'api.dart',
          'modules/admin.dart',
          'modules/admin/users.dart',
          'modules/messages.dart',
          'runtime.dart',
          'schema.dart',
        ],
      );
      expect(output.warnings, hasLength(1));
      expect(output.warnings.single, contains('Skipping HTTP action'));
    });

    test('matches golden files for core outputs', () async {
      final output = DartGenerator().generate(spec);

      final expectedApi = await File(
        path.join('test', 'goldens', 'sample', 'api.dart'),
      ).readAsString();
      final expectedMessages = await File(
        path.join('test', 'goldens', 'sample', 'modules', 'messages.dart'),
      ).readAsString();
      final expectedUsers = await File(
        path.join(
          'test',
          'goldens',
          'sample',
          'modules',
          'admin',
          'users.dart',
        ),
      ).readAsString();
      final expectedSchema = await File(
        path.join('test', 'goldens', 'sample', 'schema.dart'),
      ).readAsString();
      final expectedRuntime = await File(
        path.join('test', 'goldens', 'sample', 'runtime.dart'),
      ).readAsString();

      expect(output.files['api.dart'], expectedApi);
      expect(output.files['modules/messages.dart'], expectedMessages);
      expect(output.files['modules/admin/users.dart'], expectedUsers);
      expect(output.files['schema.dart'], expectedSchema);
      expect(output.files['runtime.dart'], expectedRuntime);
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
        api,
        contains('QueryError(:final message, :final data, :final logLines)'),
      );
      expect(api, contains('QueryLoading(:final hasPendingWrites)'));
      expect(
          messages,
          contains(
              "if (attachment.isDefined) 'attachment': attachment.value,"));
      expect(users,
          contains('typedef SyncTypeResult = ({bool success, BigInt count});'));
      expect(
          users,
          contains(
              "count: expectBigInt(map['count'], label: 'SyncTypeResultCount')"));
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

      expect(
        api,
        contains(r"import './modules/weird\$module\'s.dart';"),
      );
      expect(
        module,
        contains(r"'weird\$module\'s:send\$public'"),
      );
      expect(
        schema,
        contains(r"static const String tableName = 'price\$table\'s';"),
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
        () => DartGenerator(naming: const _InvalidMethodNaming())
            .generate(invalidSpec),
        throwsA(
          isA<GenerationException>().having(
            (error) => error.message,
            'message',
            contains('could not be formatted'),
          ),
        ),
      );
    });
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
