import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

/// An [http.Client] wrapper whose [close] is safe to call while requests are
/// still running.
///
/// `CupertinoClient` (cupertino_http 3.x) throws a [StateError] from `close()`
/// when any request is still in flight, while every other `package:http`
/// client (and every call site in the Dartvex packages, which close a client
/// in a `finally` block after a timeout or failure) treats `close()` as always
/// safe. This wrapper restores that contract: [close] rejects new requests
/// immediately and closes the wrapped client once the last in-flight request,
/// including its response body stream, has finished or been cancelled.
@internal
class DeferredCloseClient extends http.BaseClient {
  /// Wraps [inner]. The wrapper owns [inner] and closes it.
  DeferredCloseClient(this._inner);

  final http.Client _inner;
  int _inFlight = 0;
  bool _closeRequested = false;
  bool _innerClosed = false;

  /// Number of requests whose response has not been fully consumed yet.
  @visibleForTesting
  int get inFlightCount => _inFlight;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_closeRequested) {
      throw http.ClientException(
        'HTTP request failed. Client is already closed.',
        request.url,
      );
    }
    _inFlight += 1;
    var released = false;
    void releaseOnce() {
      if (released) {
        return;
      }
      released = true;
      _release();
    }

    // A caller that timed out never listens to a body that arrives afterwards.
    // Cancel that body too, but wait for native cancellation before closing.
    var aborted = false;
    void Function()? onAbort;
    if (request case http.Abortable(:final abortTrigger?)) {
      unawaited(
        abortTrigger
            .whenComplete(() {
              aborted = true;
              onAbort?.call();
            })
            .then((_) {}, onError: (Object _) {}),
      );
    }

    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (_) {
      releaseOnce();
      rethrow;
    }

    var listened = false;
    StreamSubscription<List<int>>? subscription;
    Future<void>? cancellation;
    late final StreamController<List<int>> controller;
    Future<void> cancelBody() {
      return cancellation ??= () async {
        try {
          subscription ??= response.stream.listen(null, onError: (Object _) {});
          await subscription!.cancel();
        } finally {
          releaseOnce();
        }
      }();
    }

    void failAborted() {
      if (!controller.isClosed) {
        controller.addError(http.RequestAbortedException(request.url));
        unawaited(controller.close());
      }
    }

    controller = StreamController<List<int>>(
      sync: true,
      onListen: () {
        listened = true;
        if (aborted) {
          failAborted();
          return;
        }
        subscription = response.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: () {
            if (cancellation == null) {
              releaseOnce();
            }
            unawaited(controller.close());
          },
        );
      },
      onPause: () => subscription?.pause(),
      onResume: () => subscription?.resume(),
      onCancel: cancelBody,
    );

    onAbort = () {
      if (released) {
        return;
      }
      // onCancel may be invoked again when failAborted closes the public
      // stream. Both paths must await the same native cancellation future.
      unawaited(cancelBody().then((_) {}, onError: (Object _) {}));
      if (listened) {
        failAborted();
      }
    };
    if (aborted) {
      onAbort();
    }

    final stream = http.ByteStream(controller.stream);
    if (response case http.BaseResponseWithUrl(:final url)) {
      return _StreamedResponseWithUrl(
        stream,
        response.statusCode,
        url: url,
        contentLength: response.contentLength,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    }
    return http.StreamedResponse(
      stream,
      response.statusCode,
      contentLength: response.contentLength,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  void _release() {
    _inFlight -= 1;
    if (_closeRequested && _inFlight == 0) {
      _closeInner();
    }
  }

  @override
  void close() {
    if (_closeRequested) {
      return;
    }
    _closeRequested = true;
    if (_inFlight == 0) {
      _closeInner();
    }
  }

  void _closeInner() {
    if (_innerClosed) {
      return;
    }
    _inner.close();
    _innerClosed = true;
  }
}

class _StreamedResponseWithUrl extends http.StreamedResponse
    implements http.BaseResponseWithUrl {
  _StreamedResponseWithUrl(
    super.stream,
    super.statusCode, {
    required this.url,
    super.contentLength,
    super.request,
    super.headers,
    super.isRedirect,
    super.persistentConnection,
    super.reasonPhrase,
  });

  @override
  final Uri url;
}
