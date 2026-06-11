import 'dart:async';
import 'dart:io';

import 'package:dartvex/src/transport/ws_native.dart';
import 'package:test/test.dart';

void main() {
  group('NativeWebSocketAdapter', () {
    test(
        'a binary frame with malformed UTF-8 surfaces as a replacement '
        'string instead of an uncaught zone error', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        // 0xC3 opens a two-byte sequence; 0x28 is not a continuation byte.
        socket.add(<int>[0xC3, 0x28, 0xFF]);
      });

      final adapter = NativeWebSocketAdapter(clientId: 'test-client');
      addTearDown(adapter.close);
      final received = <String>[];
      final errors = <Object>[];
      await runZonedGuarded(() async {
        adapter.messages.listen(received.add);
        await adapter.connect('ws://127.0.0.1:${server.port}');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }, (error, stackTrace) {
        errors.add(error);
      });

      expect(
        errors,
        isEmpty,
        reason: 'malformed network input must never escape the adapter as an '
            'uncaught zone error — that kills the isolate in a pure-Dart app',
      );
      expect(received, hasLength(1));
      expect(
        received.single,
        contains('�'),
        reason: 'malformed bytes decode with replacement characters; the '
            'garbled message then fails JSON parsing upstream, which drives '
            'the InvalidServerMessage reconnect instead of a crash',
      );
    });
  });
}
