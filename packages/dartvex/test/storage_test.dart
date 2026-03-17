import 'dart:convert';
import 'dart:typed_data';

import 'package:dartvex/dartvex.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

/// Minimal fake that implements [ConvexFunctionCaller] for unit tests.
class _FakeCaller implements ConvexFunctionCaller {
  final Map<String, dynamic Function(Map<String, dynamic>)> mutations =
      <String, dynamic Function(Map<String, dynamic>)>{};
  final Map<String, dynamic Function(Map<String, dynamic>)> queries =
      <String, dynamic Function(Map<String, dynamic>)>{};

  @override
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    return mutations[name]!(args);
  }

  @override
  Future<dynamic> query(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    return queries[name]!(args);
  }

  @override
  Future<T> queryOnce<T>(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    final result = await query(name, args);
    return result as T;
  }

  @override
  ConvexSubscription subscribe(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    throw UnimplementedError();
  }
}

void main() {
  group('ConvexStorage', () {
    test('uploadFile returns storageId on success', () async {
      final caller = _FakeCaller()
        ..mutations['files:generateUploadUrl'] =
            (_) => 'https://upload.convex.cloud/abc123';

      final mockHttp = http_testing.MockClient((request) async {
        expect(request.url.toString(), 'https://upload.convex.cloud/abc123');
        expect(request.headers['Content-Type'], 'image/jpeg');
        return http.Response(
          jsonEncode({'storageId': 'kg2abc123'}),
          200,
        );
      });

      final storage = ConvexStorage(caller, httpClient: mockHttp);
      final storageId = await storage.uploadFile(
        uploadUrlAction: 'files:generateUploadUrl',
        bytes: Uint8List.fromList([1, 2, 3]),
        filename: 'photo.jpg',
        contentType: 'image/jpeg',
      );

      expect(storageId, 'kg2abc123');
    });

    test('uploadFile passes uploadUrlArgs to mutation', () async {
      Map<String, dynamic>? capturedArgs;
      final caller = _FakeCaller()
        ..mutations['files:generateUploadUrl'] = (args) {
          capturedArgs = args;
          return 'https://upload.convex.cloud/abc123';
        };

      final mockHttp = http_testing.MockClient((_) async {
        return http.Response(jsonEncode({'storageId': 'id1'}), 200);
      });

      final storage = ConvexStorage(caller, httpClient: mockHttp);
      await storage.uploadFile(
        uploadUrlAction: 'files:generateUploadUrl',
        bytes: Uint8List(0),
        filename: 'f.txt',
        contentType: 'text/plain',
        uploadUrlArgs: {'bucket': 'docs'},
      );

      expect(capturedArgs, {'bucket': 'docs'});
    });

    test('uploadFile throws ConvexFileUploadException on non-200', () async {
      final caller = _FakeCaller()
        ..mutations['files:generateUploadUrl'] =
            (_) => 'https://upload.convex.cloud/abc';

      final mockHttp = http_testing.MockClient((_) async {
        return http.Response('File too large', 413);
      });

      final storage = ConvexStorage(caller, httpClient: mockHttp);
      expect(
        () => storage.uploadFile(
          uploadUrlAction: 'files:generateUploadUrl',
          bytes: Uint8List(0),
          filename: 'big.bin',
          contentType: 'application/octet-stream',
        ),
        throwsA(
          isA<ConvexFileUploadException>()
              .having((e) => e.statusCode, 'statusCode', 413)
              .having((e) => e.body, 'body', 'File too large'),
        ),
      );
    });

    test('getFileUrl returns URL from query', () async {
      final caller = _FakeCaller()
        ..queries['files:getUrl'] = (args) {
          expect(args['storageId'], 'kg2abc123');
          return 'https://cdn.convex.cloud/file/kg2abc123';
        };

      final storage = ConvexStorage(caller);
      final url = await storage.getFileUrl(
        getUrlAction: 'files:getUrl',
        storageId: 'kg2abc123',
      );

      expect(url, 'https://cdn.convex.cloud/file/kg2abc123');
    });
  });
}
