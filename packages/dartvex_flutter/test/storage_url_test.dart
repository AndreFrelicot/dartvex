import 'package:dartvex/dartvex.dart' show ConvexStorageException;
import 'package:dartvex_flutter/src/storage_url.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('requireStorageUrl', () {
    test('returns a non-empty URL string', () {
      expect(
        requireStorageUrl('https://example.com/image.png', 'img-1'),
        'https://example.com/image.png',
      );
    });

    test('throws ConvexStorageException for unusable resolver values', () {
      for (final value in <Object?>[null, '', <String, dynamic>{}]) {
        expect(
          () => requireStorageUrl(value, 'img-1'),
          throwsA(isA<ConvexStorageException>()),
        );
      }
    });
  });
}
