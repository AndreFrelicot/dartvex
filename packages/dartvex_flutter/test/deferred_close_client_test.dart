import 'dart:async';

import 'package:dartvex_flutter/src/transport/deferred_close_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Mimics cupertino_http 3's CupertinoClient: close() throws while a request
/// (including its body stream) is still running.
class StrictCloseClient extends http.BaseClient {
  int running = 0;
  int closeCalls = 0;
  bool closed = false;
  final List<StreamController<List<int>>> bodies =
      <StreamController<List<int>>>[];
  Completer<void>? holdHeaders;
  Object? sendError;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    running += 1;
    final hold = holdHeaders;
    if (hold != null) {
      await hold.future;
    }
    final error = sendError;
    if (error != null) {
      running -= 1;
      throw error;
    }
    late final StreamController<List<int>> body;
    body = StreamController<List<int>>(
      onCancel: () {
        running -= 1;
      },
    );
    bodies.add(body);
    return http.StreamedResponse(body.stream, 200);
  }

  void finishBody(int index) {
    unawaited(bodies[index].close());
  }

  @override
  void close() {
    closeCalls += 1;
    if (running > 0) {
      throw StateError('cannot close with running requests');
    }
    closed = true;
  }
}

void main() {
  test('close with no request in flight closes the inner client', () {
    final inner = StrictCloseClient();
    DeferredCloseClient(inner).close();
    expect(inner.closed, isTrue);
  });

  test('close while a body is streaming waits for it to finish', () async {
    final inner = StrictCloseClient();
    final client = DeferredCloseClient(inner);
    final response = await client.send(
      http.Request('GET', Uri.parse('https://example.com')),
    );
    final received = <List<int>>[];
    final done = Completer<void>();
    response.stream.listen(received.add, onDone: done.complete);

    expect(client.close, returnsNormally);
    expect(inner.closeCalls, 0);

    inner.bodies.single.add(<int>[1, 2]);
    inner.finishBody(0);
    await done.future;

    expect(received, <List<int>>[
      <int>[1, 2],
    ]);
    expect(inner.closed, isTrue);
    expect(client.inFlightCount, 0);
  });

  test('cancelling the body releases the request', () async {
    final inner = StrictCloseClient();
    final client = DeferredCloseClient(inner);
    final response = await client.send(
      http.Request('GET', Uri.parse('https://example.com')),
    );
    final subscription = response.stream.listen((_) {});
    client.close();
    expect(inner.closed, isFalse);

    await subscription.cancel();
    expect(inner.closed, isTrue);
  });

  test('a request still waiting for headers defers close', () async {
    final inner = StrictCloseClient()..holdHeaders = Completer<void>();
    final client = DeferredCloseClient(inner);
    final pending = client.send(
      http.Request('GET', Uri.parse('https://example.com')),
    );

    // e.g. the caller's own timeout fired and its finally block closes.
    client.close();
    expect(inner.closeCalls, 0);

    inner
      ..sendError = http.ClientException('aborted')
      ..holdHeaders!.complete();
    await expectLater(pending, throwsA(isA<http.ClientException>()));
    expect(inner.closed, isTrue);
  });

  test('an aborted request whose response is never read releases the '
      'close', () async {
    // A caller that timed out waiting for the headers aborts and moves on;
    // the response still arrives (the inner client ignores the abort, or it
    // raced with it) and nobody ever listens to its body.
    final inner = StrictCloseClient()..holdHeaders = Completer<void>();
    final client = DeferredCloseClient(inner);
    final abort = Completer<void>();
    final pending = client.send(
      http.AbortableRequest(
        'GET',
        Uri.parse('https://example.com'),
        abortTrigger: abort.future,
      ),
    );

    abort.complete();
    client.close();
    inner.holdHeaders!.complete();
    final response = await pending;
    await pumpEventQueue();

    expect(client.inFlightCount, 0);
    expect(inner.closed, isTrue);
    // A late reader sees the abort instead of hanging.
    await expectLater(
      response.stream.toList(),
      throwsA(isA<http.RequestAbortedException>()),
    );
  });

  test('aborting while the body streams cancels it and releases the '
      'close', () async {
    final inner = StrictCloseClient();
    final client = DeferredCloseClient(inner);
    final abort = Completer<void>();
    final response = await client.send(
      http.AbortableRequest(
        'GET',
        Uri.parse('https://example.com'),
        abortTrigger: abort.future,
      ),
    );
    final errors = <Object>[];
    final done = Completer<void>();
    response.stream.listen((_) {}, onError: errors.add, onDone: done.complete);
    client.close();

    abort.complete();
    await done.future;

    expect(errors.single, isA<http.RequestAbortedException>());
    expect(client.inFlightCount, 0);
    expect(inner.closed, isTrue);
  });

  test('requests after close are rejected', () async {
    final client = DeferredCloseClient(StrictCloseClient())..close();
    await expectLater(
      client.get(Uri.parse('https://example.com')),
      throwsA(isA<http.ClientException>()),
    );
  });
}
