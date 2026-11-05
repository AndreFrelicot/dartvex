import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartvex/dartvex.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:test/test.dart';

/// Models a transport that stays active until the request is aborted.
class _StalledUploadClient extends http.BaseClient {
  _StalledUploadClient({required this.waitForHeaders});

  final bool waitForHeaders;
  final aborted = Completer<void>();
  bool active = false;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    active = true;
    final abort = (request as http.Abortable).abortTrigger!;
    if (waitForHeaders) {
      await abort;
      active = false;
      aborted.complete();
      throw http.RequestAbortedException(request.url);
    }
    final body = StreamController<List<int>>();
    unawaited(abort.then((_) async {
      active = false;
      body.addError(http.RequestAbortedException(request.url));
      await body.close();
      aborted.complete();
    }));
    return http.StreamedResponse(body.stream, 200);
  }

  @override
  void close() => closed = true;
}

/// Minimal fake that implements [ConvexFunctionCaller] for unit tests.
class _FakeCaller implements ConvexFunctionCaller {
  final Map<String, dynamic Function(Map<String, dynamic>)> mutations =
      <String, dynamic Function(Map<String, dynamic>)>{};
  final Map<String, dynamic Function(Map<String, dynamic>)> queries =
      <String, dynamic Function(Map<String, dynamic>)>{};
  final Map<String, dynamic Function(Map<String, dynamic>)> actions =
      <String, dynamic Function(Map<String, dynamic>)>{};

  @override
  Future<dynamic> mutate(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
    OptimisticUpdate? optimisticUpdate,
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
  ConvexPaginatedQuery paginatedQuery(
    String name,
    Map<String, dynamic> args, {
    int pageSize = 20,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<dynamic> action(
    String name, [
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) async {
    return actions[name]!(args);
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
        expect(request.bodyBytes, <int>[1, 2, 3]);
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

    test('uploadFile can resolve the upload URL from an action', () async {
      final caller = _FakeCaller()
        ..actions['files:generateUploadUrl'] =
            (_) => 'https://upload.convex.cloud/from-action';
      final mockHttp = http_testing.MockClient((request) async {
        expect(request.url.path, '/from-action');
        return http.Response(jsonEncode({'storageId': 'id-action'}), 200);
      });

      final storage = ConvexStorage(caller, httpClient: mockHttp);
      final storageId = await storage.uploadFile(
        uploadUrlAction: 'files:generateUploadUrl',
        bytes: Uint8List(0),
        contentType: 'text/plain',
        useAction: true,
      );

      expect(storageId, 'id-action');
      expect(caller.mutations, isEmpty);
    });

    test('uploadFile does not require a filename', () async {
      final caller = _FakeCaller()
        ..mutations['files:generateUploadUrl'] =
            (_) => 'https://upload.convex.cloud/abc';
      final mockHttp = http_testing.MockClient(
        (_) async => http.Response(jsonEncode({'storageId': 'id2'}), 200),
      );

      final storage = ConvexStorage(caller, httpClient: mockHttp);
      expect(
        await storage.uploadFile(
          uploadUrlAction: 'files:generateUploadUrl',
          bytes: Uint8List(0),
          contentType: 'text/plain',
        ),
        'id2',
      );
    });

    test('uploadFile throws TimeoutException when the upload stalls', () async {
      final caller = _FakeCaller()
        ..mutations['files:generateUploadUrl'] =
            (_) => 'https://upload.convex.cloud/slow';
      final stalled = Completer<http.Response>();
      final mockHttp = http_testing.MockClient((_) => stalled.future);

      final storage = ConvexStorage(caller, httpClient: mockHttp);
      await expectLater(
        storage.uploadFile(
          uploadUrlAction: 'files:generateUploadUrl',
          bytes: Uint8List(0),
          contentType: 'text/plain',
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('uploadFile rejects a non-positive timeout', () async {
      final storage = ConvexStorage(_FakeCaller());
      expect(
        () => storage.uploadFile(
          uploadUrlAction: 'files:generateUploadUrl',
          bytes: Uint8List(0),
          contentType: 'text/plain',
          timeout: Duration.zero,
        ),
        throwsArgumentError,
      );
    });

    for (final waitForHeaders in <bool>[false, true]) {
      test(
          'upload timeout aborts a shared client request (headers: $waitForHeaders)',
          () async {
        final caller = _FakeCaller()
          ..mutations['files:upload'] =
              (_) => 'https://upload.convex.cloud/slow';
        final transport = _StalledUploadClient(waitForHeaders: waitForHeaders);
        final storage = ConvexStorage(caller, httpClient: transport);
        await expectLater(
            storage.uploadFile(
              uploadUrlAction: 'files:upload',
              bytes: Uint8List.fromList([1, 2, 3]),
              contentType: 'image/jpeg',
              timeout: const Duration(milliseconds: 20),
            ),
            throwsA(isA<TimeoutException>()));
        await transport.aborted.future;
        expect(transport.closed, isFalse);
        expect(transport.active, isFalse);
      });
    }

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

    test('uploadFile throws typed exception when resolver returns non-string',
        () async {
      final caller = _FakeCaller()
        ..mutations['files:generateUploadUrl'] = (_) => <String, dynamic>{
              'url': 'https://upload.convex.cloud/abc',
            };

      final storage = ConvexStorage(
        caller,
        httpClient: http_testing.MockClient((_) async {
          fail('HTTP upload should not start for an invalid resolver result');
        }),
      );

      await expectLater(
        () => storage.uploadFile(
          uploadUrlAction: 'files:generateUploadUrl',
          bytes: Uint8List(0),
          filename: 'photo.jpg',
          contentType: 'image/jpeg',
        ),
        throwsA(
          isA<ConvexStorageException>().having(
            (error) => error.message,
            'message',
            contains('must return a non-empty string'),
          ),
        ),
      );
    });

    test('uploadFile throws typed exception when resolver URL is invalid',
        () async {
      final caller = _FakeCaller()
        ..mutations['files:generateUploadUrl'] =
            (_) => 'https://upload.convex.cloud/abc';

      for (final uploadUrl in <String>[
        'ftp://upload.convex.cloud/abc',
        'https:///missing-host',
      ]) {
        caller.mutations['files:generateUploadUrl'] = (_) => uploadUrl;
        final storage = ConvexStorage(
          caller,
          httpClient: http_testing.MockClient((_) async {
            fail('HTTP upload should not start for $uploadUrl');
          }),
        );

        await expectLater(
          () => storage.uploadFile(
            uploadUrlAction: 'files:generateUploadUrl',
            bytes: Uint8List(0),
            filename: 'photo.jpg',
            contentType: 'image/jpeg',
          ),
          throwsA(isA<ConvexStorageException>()),
        );
      }
    });

    test('uploadFile throws typed exception on malformed success body',
        () async {
      final caller = _FakeCaller()
        ..mutations['files:generateUploadUrl'] =
            (_) => 'https://upload.convex.cloud/abc';

      for (final body in <String>[
        '',
        jsonEncode(<String>[]),
        jsonEncode(<String, dynamic>{}),
        jsonEncode(<String, dynamic>{'storageId': 42}),
        jsonEncode(<String, dynamic>{'storageId': ''}),
      ]) {
        final storage = ConvexStorage(
          caller,
          httpClient: http_testing.MockClient((_) async {
            return http.Response(body, 200);
          }),
        );

        await expectLater(
          () => storage.uploadFile(
            uploadUrlAction: 'files:generateUploadUrl',
            bytes: Uint8List(0),
            filename: 'photo.jpg',
            contentType: 'image/jpeg',
          ),
          throwsA(
            isA<ConvexFileUploadException>().having(
              (error) => error.statusCode,
              'statusCode',
              200,
            ),
          ),
        );
      }
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

    test('getFileUrl returns URL from action when requested', () async {
      final caller = _FakeCaller()
        ..actions['files:getUrl'] = (args) {
          expect(args['storageId'], 'kg2abc123');
          return 'https://cdn.convex.cloud/file/kg2abc123';
        };

      final storage = ConvexStorage(caller);
      final url = await storage.getFileUrl(
        getUrlAction: 'files:getUrl',
        storageId: 'kg2abc123',
        useAction: true,
      );

      expect(url, 'https://cdn.convex.cloud/file/kg2abc123');
    });

    test('getFileUrl throws ConvexStorageException when resolver returns null',
        () async {
      final caller = _FakeCaller()..queries['files:getUrl'] = (_) => null;

      final storage = ConvexStorage(caller);

      expect(
        () => storage.getFileUrl(
          getUrlAction: 'files:getUrl',
          storageId: 'missing',
        ),
        throwsA(
          isA<ConvexStorageException>().having(
            (error) => error.message,
            'message',
            contains('No URL returned for storageId missing'),
          ),
        ),
      );
    });
  });
}
