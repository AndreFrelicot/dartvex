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
        const ConvexUnionType(<ConvexType>[
          ConvexLiteralType('draft'),
          ConvexLiteralType('sent'),
        ]),
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
        const ConvexUnionType(<ConvexType>[
          ConvexStringType(),
          ConvexNumberType(),
        ]),
        suggestedName: 'PayloadEntry',
        context: context,
      );
      final objectType = mapper.mapType(
        const ConvexObjectType(<String, ConvexField>{
          'name': ConvexField(fieldType: ConvexStringType(), optional: false),
          'description': ConvexField(
            fieldType: ConvexStringType(),
            optional: true,
          ),
        }),
        suggestedName: 'Task',
        context: context,
      );

      expect(unionType.annotation, 'PayloadEntry');
      expect(
        context.renderDefinitions(),
        contains('sealed class PayloadEntry'),
      );
      expect(objectType.annotation, 'Task');
      expect(context.renderDefinitions(), contains('typedef Task = ({'));
      expect(
        context.renderDefinitions(),
        contains('Optional<String> description'),
      );
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
        const ConvexObjectType(<String, ConvexField>{
          "it's_done": ConvexField(
            fieldType: ConvexBooleanType(),
            optional: false,
          ),
          r'price$usd': ConvexField(
            fieldType: ConvexNumberType(),
            optional: false,
          ),
        }),
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
        const ConvexUnionType(<ConvexType>[
          ConvexStringType(),
          ConvexNumberType(),
        ]),
        suggestedName: 'MixedValue',
        context: context,
      );

      final definitions = context.renderDefinitions();
      expect(definitions, contains('final errors = <String>[];'));
      expect(definitions, contains('errors.add('));
      expect(definitions, contains('Tried:'));
    });

    test('maps unions containing any to dynamic', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      final mapped = mapper.mapType(
        const ConvexUnionType(<ConvexType>[
          ConvexAnyType(),
          ConvexStringType(),
        ]),
        suggestedName: 'Anything',
        context: context,
      );

      expect(mapped.annotation, 'dynamic');
      expect(mapped.encode('value'), 'value');
      expect(mapped.decode('raw'), 'raw');
      expect(context.renderDefinitions(), isEmpty);
    });

    test('collapses literals covered by broader scalar union members', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      final mapped = mapper.mapType(
        const ConvexUnionType(<ConvexType>[
          ConvexLiteralType(1),
          ConvexNumberType(),
        ]),
        suggestedName: 'Count',
        context: context,
      );

      expect(mapped.annotation, 'double');
      expect(mapped.decode('raw'), contains('expectDouble'));
      expect(context.renderDefinitions(), isEmpty);
    });

    test('maps object unions with a required literal discriminator', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      final mapped = mapper.mapType(
        const ConvexUnionType(<ConvexType>[
          ConvexObjectType(<String, ConvexField>{
            'kind': ConvexField(
              fieldType: ConvexLiteralType('text'),
              optional: false,
            ),
            'body': ConvexField(fieldType: ConvexStringType(), optional: false),
          }),
          ConvexObjectType(<String, ConvexField>{
            'kind': ConvexField(
              fieldType: ConvexLiteralType('image'),
              optional: false,
            ),
            'url': ConvexField(fieldType: ConvexStringType(), optional: false),
          }),
        ]),
        suggestedName: 'MessagePayload',
        context: context,
      );

      expect(mapped.annotation, 'MessagePayload');
      expect(
        context.renderDefinitions(),
        contains('sealed class MessagePayload'),
      );
    });

    test('throws on object unions without a discriminator', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      expect(
        () => mapper.mapType(
          const ConvexUnionType(<ConvexType>[
            ConvexObjectType(<String, ConvexField>{
              'body': ConvexField(
                fieldType: ConvexStringType(),
                optional: false,
              ),
            }),
            ConvexObjectType(<String, ConvexField>{
              'url': ConvexField(
                fieldType: ConvexStringType(),
                optional: false,
              ),
            }),
          ]),
          suggestedName: 'AmbiguousPayload',
          context: context,
        ),
        throwsA(
          isA<TypeMapperException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Ambiguous union "AmbiguousPayload"'),
              contains('required literal discriminator'),
            ),
          ),
        ),
      );
    });

    test('throws on runtime-overlapping array unions', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      expect(
        () => mapper.mapType(
          const ConvexUnionType(<ConvexType>[
            ConvexArrayType(ConvexStringType()),
            ConvexArrayType(ConvexNumberType()),
          ]),
          suggestedName: 'AmbiguousList',
          context: context,
        ),
        throwsA(
          isA<TypeMapperException>().having(
            (e) => e.message,
            'message',
            contains('Ambiguous union "AmbiguousList"'),
          ),
        ),
      );
    });

    test('throws on field name collision in objects', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      // foo_bar and foo-bar both split to ['foo', 'bar'] → fooBar
      expect(
        () => mapper.mapType(
          const ConvexObjectType(<String, ConvexField>{
            'foo_bar': ConvexField(
              fieldType: ConvexStringType(),
              optional: false,
            ),
            'foo-bar': ConvexField(
              fieldType: ConvexStringType(),
              optional: false,
            ),
          }),
          suggestedName: 'Collide',
          context: context,
        ),
        throwsA(
          isA<TypeMapperException>().having(
            (e) => e.message,
            'message',
            allOf(contains('foo_bar'), contains('foo-bar'), contains('fooBar')),
          ),
        ),
      );
    });

    test('generated object decoders require fields that decode to null', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      mapper.mapType(
        const ConvexObjectType(<String, ConvexField>{
          'deletedAt': ConvexField(
            fieldType: ConvexNullType(),
            optional: false,
          ),
          'archivedAt': ConvexField(
            fieldType: ConvexNullType(),
            optional: true,
          ),
        }),
        suggestedName: 'Tombstone',
        context: context,
      );

      final definitions = context.renderDefinitions();
      expect(definitions, contains("if (!map.containsKey('deletedAt'))"));
      expect(
        definitions,
        contains(
          "throw FormatException('Missing required field \"deletedAt\" for Tombstone')",
        ),
      );
      expect(
        definitions,
        isNot(contains("if (!map.containsKey('archivedAt'))")),
      );
    });

    test('deduplicates colliding enum value names', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      // foo_bar and foo-bar both produce fooBarValue
      mapper.mapType(
        const ConvexUnionType(<ConvexType>[
          ConvexLiteralType('foo_bar'),
          ConvexLiteralType('foo-bar'),
        ]),
        suggestedName: 'CollidingEnum',
        context: context,
      );

      final definitions = context.renderDefinitions();
      // Both should have distinct names with index suffixes
      expect(definitions, contains('fooBarValue0'));
      expect(definitions, contains('fooBarValue1'));
    });

    test('deduplicates repeated literal union members', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      mapper.mapType(
        const ConvexUnionType(<ConvexType>[
          ConvexLiteralType('draft'),
          ConvexLiteralType('sent'),
          ConvexLiteralType('sent'),
        ]),
        suggestedName: 'DuplicateStatus',
        context: context,
      );

      final definitions = context.renderDefinitions();
      expect(RegExp(r"case 'draft':").allMatches(definitions), hasLength(1));
      expect(RegExp(r"case 'sent':").allMatches(definitions), hasLength(1));
    });

    test('escapes literal union enum error messages', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      mapper.mapType(
        const ConvexUnionType(<ConvexType>[
          ConvexLiteralType("can't"),
          ConvexLiteralType(r'price$total'),
          ConvexLiteralType('line1\nline2'),
        ]),
        suggestedName: 'SpecialStatus',
        context: context,
      );

      final definitions = context.renderDefinitions();
      expect(
        definitions,
        contains(
          r"Expected one of can\'t, price\$total, line1\nline2 "
          'for SpecialStatus',
        ),
      );
    });

    test('degrades a non-scalar literal value to dynamic with a warning', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      // A Convex $integer-encoded bigint literal arrives as a Map after JSON
      // decoding; it has no Dart constant form, so it degrades to dynamic.
      final mapped = mapper.mapType(
        ConvexLiteralType(<String, dynamic>{r'$integer': 'BQAAAAAAAAA='}),
        suggestedName: 'BigLiteral',
        context: context,
      );

      expect(mapped.annotation, 'dynamic');
      expect(mapped.encode('value'), 'value');
      expect(mapped.decode('raw'), 'raw');
      expect(context.warnings, anyElement(contains('BigLiteral')));
    });

    test(
      'degrades a union with a non-scalar literal to dynamic with a warning',
      () {
        final context = TypeRenderContext();
        final mapper = TypeMapper();

        final mapped = mapper.mapType(
          ConvexUnionType(<ConvexType>[
            ConvexLiteralType(<String, dynamic>{r'$integer': 'BQAAAAAAAAA='}),
            const ConvexStringType(),
          ]),
          suggestedName: 'MaybeBig',
          context: context,
        );

        expect(mapped.annotation, 'dynamic');
        expect(mapped.encode('value'), 'value');
        expect(mapped.decode('raw'), 'raw');
        expect(context.warnings, anyElement(contains('MaybeBig')));
      },
    );

    test('collapses unions of only null members to Null', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      final nullOnly = mapper.mapType(
        const ConvexUnionType(<ConvexType>[ConvexNullType(), ConvexNullType()]),
        suggestedName: 'NothingResult',
        context: context,
      );
      final nullAndNullLiteral = mapper.mapType(
        const ConvexUnionType(<ConvexType>[
          ConvexNullType(),
          ConvexLiteralType(null),
        ]),
        suggestedName: 'AlsoNothing',
        context: context,
      );

      // Without the collapse these rendered an empty — invalid — Dart enum.
      expect(nullOnly.annotation, 'Null');
      expect(nullOnly.decode('raw'), 'null');
      expect(nullAndNullLiteral.annotation, 'Null');
    });

    test('does not double-wrap nested nullable unions', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      final nestedNullableId = mapper.mapType(
        const ConvexUnionType(<ConvexType>[
          ConvexNullType(),
          ConvexUnionType(<ConvexType>[
            ConvexNullType(),
            ConvexIdType('users'),
          ]),
        ]),
        suggestedName: 'NestedTarget',
        context: context,
      );
      final nestedDynamic = mapper.mapType(
        const ConvexUnionType(<ConvexType>[
          ConvexNullType(),
          ConvexUnionType(<ConvexType>[ConvexAnyType(), ConvexStringType()]),
        ]),
        suggestedName: 'NestedAny',
        context: context,
      );

      // Without the guard these rendered invalid `UsersId??` / `dynamic?`.
      expect(nestedNullableId.annotation, 'UsersId?');
      expect(nestedDynamic.annotation, 'dynamic');
    });

    test('encodes nullable composite types through a promoted binding', () {
      final context = TypeRenderContext();
      final mapper = TypeMapper();

      final nullableId = mapper.mapType(
        const ConvexUnionType(<ConvexType>[
          ConvexIdType('users'),
          ConvexNullType(),
        ]),
        suggestedName: 'Target',
        context: context,
      );
      final nullableString = mapper.mapType(
        const ConvexUnionType(<ConvexType>[
          ConvexStringType(),
          ConvexNullType(),
        ]),
        suggestedName: 'Label',
        context: context,
      );

      // `x.value == null ? null : x.value.value` does not compile when the
      // receiver is a non-promotable getter such as Optional.value; the
      // encode must bind through a promoting switch expression instead.
      expect(
        nullableId.encode('x.value'),
        r'switch (x.value) { null => null, final v$ => v$.value }',
      );
      // Identity inner encodes need no null handling at all.
      expect(nullableString.encode('x.value'), 'x.value');
    });
  });
}
