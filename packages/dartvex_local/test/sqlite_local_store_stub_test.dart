// Tests for the web/stub SqliteLocalStore behavior.
//
// The stub is selected via conditional import on non-native platforms (web).
// On native platforms, we import and test the stub directly to verify it
// throws UnsupportedError for all operations.

import 'package:dartvex_local/src/storage/sqlite_local_store_stub.dart' as stub;
import 'package:test/test.dart';

void main() {
  group('SqliteLocalStore stub (web target behavior)', () {
    test('open() throws UnsupportedError', () {
      expect(
        () => stub.SqliteLocalStore.open('/tmp/test.db'),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('openInMemory() throws UnsupportedError', () {
      expect(
        () => stub.SqliteLocalStore.openInMemory(),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}
