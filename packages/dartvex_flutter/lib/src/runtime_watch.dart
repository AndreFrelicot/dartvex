import 'dart:async';

import 'runtime_client.dart';
import 'snapshot.dart';

/// Decoded [Stream] view of a live query, for code outside widgets
/// (controllers, repositories, services).
extension ConvexRuntimeWatch on ConvexRuntimeClient {
  /// Watches the live query [name] with [args] as a stream of decoded values.
  ///
  /// The query is subscribed when the stream is listened to and unsubscribed
  /// when that listener cancels, so `first`, `take`, a `break` out of an
  /// `await for` loop or an `onCancel` all release the server subscription.
  /// The returned stream is single-subscription.
  ///
  /// - Each successful value goes through [decode] (a plain `as T` cast when
  ///   omitted); an error thrown by [decode] is delivered as a stream error
  ///   and the stream stays open.
  /// - A query error is delivered as a stream error (a `ConvexException` with
  ///   `ConvexClientRuntime`); the stream stays open.
  /// - Loading events are skipped.
  ///
  /// A new subscription may first replay the result cached after an earlier
  /// subscription to the same query was cancelled (a [ConvexQuerySource.cache]
  /// event without pending writes), which can be stale until the server
  /// answers. Pass `skipCached: true` to drop that seed, so `first` waits for
  /// a value confirmed by the server. Optimistic values are always delivered.
  ///
  /// ```dart
  /// final messages = ConvexProvider.of(context).watch(
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
    ConvexRuntimeSubscription? subscription;
    StreamSubscription<ConvexRuntimeQueryEvent>? events;
    late final StreamController<T> controller;
    bool isCachedSeed(ConvexRuntimeQueryEvent event) =>
        skipCached &&
        event.source == ConvexQuerySource.cache &&
        !event.hasPendingWrites;
    controller = StreamController<T>(
      onListen: () {
        final ConvexRuntimeSubscription opened;
        try {
          opened = subscribe(name, args);
        } catch (error, stackTrace) {
          controller.addError(error, stackTrace);
          unawaited(controller.close());
          return;
        }
        subscription = opened;
        events = opened.stream.listen(
          (event) {
            if (isCachedSeed(event)) {
              return;
            }
            switch (event) {
              case ConvexRuntimeQuerySuccess(:final value):
                final T decoded;
                try {
                  decoded = decode == null ? value as T : decode(value);
                } catch (error, stackTrace) {
                  controller.addError(error, stackTrace);
                  return;
                }
                controller.add(decoded);
              case ConvexRuntimeQueryError(:final error, :final stackTrace):
                controller.addError(error, stackTrace);
              case ConvexRuntimeQueryLoading():
                break;
            }
          },
          onError: controller.addError,
          onDone: () => unawaited(controller.close()),
        );
      },
      onPause: () => events?.pause(),
      onResume: () => events?.resume(),
      onCancel: () async {
        final listening = events;
        events = null;
        subscription?.cancel();
        subscription = null;
        await listening?.cancel();
      },
    );
    return controller.stream;
  }
}
