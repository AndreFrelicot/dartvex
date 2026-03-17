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
      expect(runtime, isNot(contains('base64Decode')));
      expect(runtime, isNot(contains('List<int>')));

      expect(api, contains('final ConvexFunctionCaller _client;'));
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
  });
}
