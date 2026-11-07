import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartvex_flutter/src/transport/cupertino_session_web_socket.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket/web_socket.dart';

/// Scriptable stand-in for an NSURLSessionWebSocketTask.
class FakeSocketTask implements CupertinoSocketTask {
  final List<Completer<WebSocketEvent>> receives =
      <Completer<WebSocketEvent>>[];
  final List<String> sentText = <String>[];
  final List<Uint8List> sentBytes = <Uint8List>[];
  Object? sendError;
  int cancelCount = 0;
  final List<(int, String)> closeFrames = <(int, String)>[];

  @override
  Future<WebSocketEvent> receive() {
    final completer = Completer<WebSocketEvent>();
    receives.add(completer);
    return completer.future;
  }

  @override
  Future<void> sendText(String text) async {
    sentText.add(text);
    final error = sendError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> sendBytes(Uint8List bytes) async {
    sentBytes.add(bytes);
    final error = sendError;
    if (error != null) {
      throw error;
    }
  }

  @override
  void cancel() => cancelCount += 1;

  @override
  void cancelWithCloseCode(int code, Uint8List reason) {
    closeFrames.add((code, utf8.decode(reason)));
  }
}

void main() {
  group('CupertinoTaskWebSocket', () {
    late FakeSocketTask task;
    late CupertinoTaskWebSocket socket;
    late List<WebSocketEvent> events;
    late Completer<void> done;

    setUp(() {
      task = FakeSocketTask();
      socket = CupertinoTaskWebSocket(task, 'proto');
      events = <WebSocketEvent>[];
      done = Completer<void>();
      socket.events.listen(events.add, onDone: done.complete);
    });

    test('delivers received frames and keeps receiving', () async {
      expect(task.receives, hasLength(1));
      task.receives.last.complete(TextDataReceived('hello'));
      await pumpEventQueue();
      task.receives.last.complete(BinaryDataReceived(Uint8List(2)));
      await pumpEventQueue();

      expect(events, hasLength(2));
      expect(events.first, TextDataReceived('hello'));
      expect(task.receives, hasLength(3));
      expect(socket.protocol, 'proto');
    });

    test(
      'a peer close frame emits one CloseReceived and ends the stream',
      () async {
        socket.handlePeerClose(4000, utf8.encode('bye'));
        // onComplete always follows the close frame; it must not emit again.
        socket.handleTaskComplete();
        await done.future;

        expect(events, <WebSocketEvent>[CloseReceived(4000, 'bye')]);
      },
    );

    test('malformed UTF-8 close reasons do not throw', () async {
      socket.handlePeerClose(4001, <int>[0xff, 0xfe]);
      await done.future;

      final close = events.single as CloseReceived;
      expect(close.code, 4001);
      expect(close.reason, contains('�'));
    });

    test(
      'task completion without a close frame is an abnormal close',
      () async {
        socket.handleTaskComplete();
        await done.future;

        expect(events, <WebSocketEvent>[CloseReceived(1006, 'abnormal close')]);
      },
    );

    test(
      'POSIX 57 receive errors wait for the delegate close callbacks',
      () async {
        task.receives.last.completeError(
          const CupertinoTaskError('NSPOSIXErrorDomain', 57, 'not connected'),
        );
        await pumpEventQueue();
        expect(events, isEmpty);
        expect(task.cancelCount, 0);

        socket.handlePeerClose(1000, null);
        await done.future;
        expect(events, <WebSocketEvent>[CloseReceived(1000, '')]);
      },
    );

    test('POSIX 100 receive errors map to a 1002 protocol close', () async {
      task.receives.last.completeError(
        const CupertinoTaskError('NSPOSIXErrorDomain', 100, 'protocol'),
      );
      await done.future;

      expect(events, <WebSocketEvent>[CloseReceived(1002, 'protocol')]);
      expect(task.cancelCount, 1);
    });

    test(
      'other native and non-native errors map to an abnormal close',
      () async {
        task.receives.last.completeError(StateError('weird'));
        await done.future;

        final close = events.single as CloseReceived;
        expect(close.code, 1006);
        expect(close.reason, contains('weird'));
        expect(task.cancelCount, 1);
      },
    );

    test('send failures close the socket', () async {
      task.sendError = const CupertinoTaskError(
        'NSURLErrorDomain',
        -1005,
        'lost',
      );
      socket.sendText('x');
      await done.future;

      expect(task.sentText, <String>['x']);
      expect(events, <WebSocketEvent>[CloseReceived(1006, 'lost')]);
    });

    test('local close sends the close frame and rejects later use', () async {
      await socket.close(1000, 'done');

      expect(task.closeFrames, <(int, String)>[(1000, 'done')]);
      expect(
        () => socket.sendText('late'),
        throwsA(isA<WebSocketConnectionClosed>()),
      );
      expect(
        () => socket.sendBytes(Uint8List(1)),
        throwsA(isA<WebSocketConnectionClosed>()),
      );
      await expectLater(
        socket.close(),
        throwsA(isA<WebSocketConnectionClosed>()),
      );
      // The delegate callbacks that follow a local close are no-ops.
      socket.handleTaskComplete();
      await done.future;
      expect(events, isEmpty);
    });

    test('close without a code cancels the task', () async {
      await socket.close();
      expect(task.cancelCount, 1);
      expect(task.closeFrames, isEmpty);
    });

    test('close validates the code and reason', () async {
      expect(() => socket.close(1001), throwsArgumentError);
      expect(() => socket.close(1000, 'x' * 124), throwsArgumentError);
    });
  });

  group('CupertinoConnectAttempt', () {
    test('resolves with the socket once the handshake succeeds', () async {
      final attempt = CupertinoConnectAttempt();
      final task = FakeSocketTask();
      attempt.opened(task, null);

      final socket = await attempt.future;
      expect(socket.protocol, '');

      final events = <WebSocketEvent>[];
      socket.events.listen(events.add);
      attempt.peerClosed(4002, utf8.encode('server'));
      attempt.completed(null);
      await pumpEventQueue();
      expect(events, <WebSocketEvent>[CloseReceived(4002, 'server')]);
    });

    test('rejects when the task fails before the handshake', () async {
      final attempt = CupertinoConnectAttempt();
      attempt.completed(
        const CupertinoTaskError('NSURLErrorDomain', -1004, 'refused'),
      );

      await expectLater(
        attempt.future,
        throwsA(
          isA<WebSocketException>().having(
            (e) => e.message,
            'message',
            contains('refused'),
          ),
        ),
      );
    });

    test(
      'rejects instead of throwing when the task ends without an error',
      () async {
        final attempt = CupertinoConnectAttempt();
        attempt.completed(null);

        await expectLater(attempt.future, throwsA(isA<WebSocketException>()));
      },
    );
  });
}
