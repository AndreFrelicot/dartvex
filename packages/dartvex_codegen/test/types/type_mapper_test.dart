import 'package:dartvex_codegen/dartvex_codegen.dart';
import 'package:test/test.dart';

void main() {
  group('TypeMapper', () {
    test('maps primitives, bigint, and bytes', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      final stringType = mapper.mapType(
        const ConvexStringType(),
        suggestedName: 'MessageText',
        context: context,
      );
      final bigintType = mapper.mapType(
        const ConvexBigIntType(),
        suggestedName: 'MessageCount',
        context: context,
      );
      final bytesType = mapper.mapType(
        const ConvexBytesType(),
        suggestedName: 'Attachment',
        context: context,
      );

      expect(stringType.annotation, 'String');
      expect(stringType.decode('raw'), contains('expectString'));
      expect(bigintType.annotation, 'BigInt');
      expect(bigintType.decode('raw'), contains('expectBigInt'));
      expect(bytesType.annotation, 'Uint8List');
      expect(bytesType.encode('payload'), 'payload');
      expect(context.usesTypedData, isTrue);
    });

    test('maps literal unions to enums and ids to typed table ids', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      final statusType = mapper.mapType(
        const ConvexUnionType(
          <ConvexType>[
            ConvexLiteralType('draft'),
            ConvexLiteralType('sent'),
          ],
        ),
        suggestedName: 'MessageStatus',
        context: context,
      );
      final idType = mapper.mapType(
        const ConvexIdType('messages'),
        suggestedName: 'MessageId',
        context: context,
      );

      expect(statusType.annotation, 'MessageStatus');
      expect(context.renderDefinitions(), contains('enum MessageStatus'));
      expect(idType.annotation, 'MessagesId');
      expect(context.tableNames, contains('messages'));
    });

    test('maps mixed unions and nested objects', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      final unionType = mapper.mapType(
        const ConvexUnionType(
          <ConvexType>[
            ConvexStringType(),
            ConvexNumberType(),
          ],
        ),
        suggestedName: 'PayloadEntry',
        context: context,
      );
      final objectType = mapper.mapType(
        const ConvexObjectType(
          <String, ConvexField>{
            'name': ConvexField(
              fieldType: ConvexStringType(),
              optional: false,
            ),
            'description': ConvexField(
              fieldType: ConvexStringType(),
              optional: true,
            ),
          },
        ),
        suggestedName: 'Task',
        context: context,
      );

      expect(unionType.annotation, 'PayloadEntry');
      expect(
          context.renderDefinitions(), contains('sealed class PayloadEntry'));
      expect(objectType.annotation, 'Task');
      expect(context.renderDefinitions(), contains('typedef Task = ({'));
      expect(context.renderDefinitions(),
          contains('Optional<String> description'));
    });

    test('escapes special characters in string literals', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      final literalWithNewline = mapper.mapType(
        ConvexLiteralType('line1\nline2'),
        suggestedName: 'Val',
        context: context,
      );
      final literalWithTab = mapper.mapType(
        ConvexLiteralType('col1\tcol2'),
        suggestedName: 'TabVal',
        context: context,
      );
      final literalWithDollar = mapper.mapType(
        const ConvexLiteralType(r'price$total'),
        suggestedName: 'DollarVal',
        context: context,
      );
      final literalWithQuote = mapper.mapType(
        const ConvexLiteralType("it's"),
        suggestedName: 'QuoteVal',
        context: context,
      );

      // Verify generated decode expressions contain escaped versions
      final newlineDecode = literalWithNewline.decode('raw');
      expect(newlineDecode, contains(r'\n'));
      expect(newlineDecode, isNot(contains('\n')));

      final tabDecode = literalWithTab.decode('raw');
      expect(tabDecode, contains(r'\t'));

      final dollarDecode = literalWithDollar.decode('raw');
      expect(dollarDecode, contains(r'\$'));

      final quoteDecode = literalWithQuote.decode('raw');
      expect(quoteDecode, contains(r"\'"));
    });

    test('escapes special characters in object field names', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      mapper.mapType(
        const ConvexObjectType(
          <String, ConvexField>{
            "it's_done": ConvexField(
              fieldType: ConvexBooleanType(),
              optional: false,
            ),
            r'price$usd': ConvexField(
              fieldType: ConvexNumberType(),
              optional: false,
            ),
          },
        ),
        suggestedName: 'SpecialFields',
        context: context,
      );

      final definitions = context.renderDefinitions();
      // Field names must be escaped in string literals
      expect(definitions, contains(r"it\'s_done"));
      expect(definitions, contains(r'price\$usd'));
    });

    test('union decode includes per-case error messages', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      mapper.mapType(
        const ConvexUnionType(
          <ConvexType>[
            ConvexStringType(),
            ConvexNumberType(),
          ],
        ),
        suggestedName: 'MixedValue',
        context: context,
      );

      final definitions = context.renderDefinitions();
      expect(definitions, contains('final errors = <String>[];'));
      expect(definitions, contains('errors.add('));
      expect(definitions, contains('Tried:'));
    });

    test('throws on field name collision in objects', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      // foo_bar and foo-bar both split to ['foo', 'bar'] → fooBar
      expect(
        () => mapper.mapType(
          const ConvexObjectType(
            <String, ConvexField>{
              'foo_bar': ConvexField(
                fieldType: ConvexStringType(),
                optional: false,
              ),
              'foo-bar': ConvexField(
                fieldType: ConvexStringType(),
                optional: false,
              ),
            },
          ),
          suggestedName: 'Collide',
          context: context,
        ),
        throwsA(isA<TypeMapperException>().having(
          (e) => e.message,
          'message',
          allOf(contains('foo_bar'), contains('foo-bar'), contains('fooBar')),
        )),
      );
    });

    test('deduplicates colliding enum value names', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      // foo_bar and foo-bar both produce fooBarValue
      mapper.mapType(
        const ConvexUnionType(
          <ConvexType>[
            ConvexLiteralType('foo_bar'),
            ConvexLiteralType('foo-bar'),
          ],
        ),
        suggestedName: 'CollidingEnum',
        context: context,
      );

      final definitions = context.renderDefinitions();
      // Both should have distinct names with index suffixes
      expect(definitions, contains('fooBarValue0'));
      expect(definitions, contains('fooBarValue1'));
    });
  });
}
