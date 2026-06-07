import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exports storage exception used by storage widgets', () {
    const error = ConvexStorageException('missing file');

    expect(error.message, 'missing file');
    expect(error.toString(), 'ConvexStorageException(missing file)');
  });
}
