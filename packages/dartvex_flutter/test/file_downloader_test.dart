import 'dart:async';
import 'dart:io';

import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('ConvexFileDownloader.download', () {
    test('downloads the body when the server responds promptly', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final payload = <int>[10, 20, 30, 40, 50];
      server.listen((request) async {
        request.response.statusCode = 200;
        request.response.add(payload);
        await request.response.close();
      });

      final bytes = await ConvexFileDownloader.download(
        'http://${server.address.host}:${server.port}/file',
        idleTimeout: const Duration(seconds: 5),
      );

      expect(bytes, equals(payload));
    });

    test('fails with HttpException when an error response body stalls '
        'without closing', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        // Send error headers and a partial body, then never close the
        // response: draining the error body must be bounded by the idle
        // timeout so the download still fails with the status error instead
        // of hanging forever.
        request.response.statusCode = 500;
        request.response.add(<int>[1, 2, 3]);
        await request.response.flush();
      });

      await expectLater(
        ConvexFileDownloader.download(
          'http://${server.address.host}:${server.port}/file',
          idleTimeout: const Duration(milliseconds: 200),
        ),
        throwsA(isA<HttpException>()),
      );
    });

    test(
      'fails with TimeoutException when the body stalls without progress',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          // Send the headers and a partial body chunk, then never close the
          // response: the body stalls, so the idle timeout must fire instead of
          // hanging the download forever.
          request.response.statusCode = 200;
          request.response.add(<int>[1, 2, 3]);
          await request.response.flush();
        });

        await expectLater(
          ConvexFileDownloader.download(
            'http://${server.address.host}:${server.port}/file',
            idleTimeout: const Duration(milliseconds: 200),
          ),
          throwsA(isA<TimeoutException>()),
        );
      },
    );

    test('uses an injected client and leaves it open', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.add(<int>[7]);
        await request.response.close();
      });
      final client = _CountingClient(http.Client());
      addTearDown(client.inner.close);
      final url = 'http://${server.address.host}:${server.port}/file';

      expect(await ConvexFileDownloader.download(url, client: client), [7]);
      expect(await ConvexFileDownloader.download(url, client: client), [7]);

      expect(client.requests, 2);
      expect(client.closed, isFalse);
    });

    test('completing abortTrigger aborts a stalled download', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.statusCode = 200;
        request.response.add(<int>[1, 2, 3]);
        await request.response.flush();
      });
      final abort = Completer<void>();

      final download = ConvexFileDownloader.download(
        'http://${server.address.host}:${server.port}/file',
        abortTrigger: abort.future,
        idleTimeout: const Duration(seconds: 10),
      );
      Timer(const Duration(milliseconds: 100), abort.complete);

      await expectLater(download, throwsA(isA<http.RequestAbortedException>()));
    });
  });
}

class _CountingClient extends http.BaseClient {
  _CountingClient(this.inner);

  final http.Client inner;
  int requests = 0;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests += 1;
    return inner.send(request);
  }

  @override
  void close() => closed = true;
}
