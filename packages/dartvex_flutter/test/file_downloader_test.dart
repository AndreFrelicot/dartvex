import 'dart:async';
import 'dart:io';

import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter_test/flutter_test.dart';

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

    test(
        'fails with HttpException when an error response body stalls '
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

    test('fails with TimeoutException when the body stalls without progress',
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
    });
  });
}
