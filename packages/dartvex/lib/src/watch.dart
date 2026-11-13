import 'dart:async';

import 'client.dart';
import 'exceptions.dart';

/// Decoded [Stream] view of a live query, for code outside widgets
/// (controllers, repositories, services).
extension ConvexWatch on ConvexFunctionCaller {
  /// Watches the live query [name] with [args] as a stream of decoded values.
  ///
  /// The query is subscribed when the stream is listened to and unsubscribed
  /// when that listener cancels, so `first`, `take`, a `break` out of an
  /// `await for` loop or an `onCancel` all release the server subscription
  /// (unlike [ConvexFunctionCaller.subscribe], whose handle must be cancelled
  /// separately). The returned stream is single-subscription: each listen of a
  /// new `watch` call opens its own subscription.
  ///
  /// - Each successful result goes through [decode] (a plain `as T` cast when
  ///   omitted); an error thrown by [decode] is delivered as a stream error
  ///   and the stream stays open.
  /// - A query error is delivered as a [ConvexException] stream error; the
  ///   stream stays open and later results keep coming.
  /// - Loading results are skipped.
  ///
  /// A new subscription may first replay the result cached after an earlier
  /// subscription to the same query was cancelled ([QuerySuccess.fromCache]),
  /// which can be stale until the server answers. Pass `skipCached: true` to drop
  /// that seed, so `first` waits for a value confirmed by the server. A value
  /// already maintained by another live subscription of the same query, and
  /// optimistic values, are always delivered.
  ///
  /// ```dart
  /// final messages = client.watch(
  ///   'messages:list',
  ///   {'channel': channelId},
  ///   decode: (value) => [for (final m in value as List) Message.fromJson(m)],
  /// );
  /// ```
  Stream<T> watch<T>(
    String name,
    Map<String, dynamic> args, {
    T Function(dynamic value)? decode,
    bool skipCached = false,
  }) {
    ConvexSubscription? subscription;
    StreamSubscription<QueryResult>? results;
    late final StreamController<T> controller;
    controller = StreamController<T>(
      onListen: () {
        final ConvexSubscription opened;
        try {
          opened = subscribe(name, args);
        } catch (error, stackTrace) {
          controller.addError(error, stackTrace);
          unawaited(controller.close());
          return;
        }
        subscription = opened;
        results = opened.stream.listen(
          (result) {
            switch (result) {
              case QuerySuccess(:final value, :final fromCache):
                if (skipCached && fromCache) {
                  return;
                }
                final T decoded;
                try {
                  decoded = decode == null ? value as T : decode(value);
                } catch (error, stackTrace) {
                  controller.addError(error, stackTrace);
                  return;
                }
                controller.add(decoded);
              case QueryError(
                  :final message,
                  :final data,
                  :final logLines,
                  :final fromCache,
                ):
                if (skipCached && fromCache) {
                  return;
                }
                controller.addError(
                  ConvexException(message, data: data, logLines: logLines),
                );
              case QueryLoading():
                break;
            }
          },
          onError: controller.addError,
          onDone: () => unawaited(controller.close()),
        );
      },
      onPause: () => results?.pause(),
      onResume: () => results?.resume(),
      onCancel: () async {
        final listening = results;
        results = null;
        subscription?.cancel();
        subscription = null;
        await listening?.cancel();
      },
    );
    return controller.stream;
  }
}
