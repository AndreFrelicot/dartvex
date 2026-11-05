import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';

import 'args.dart';
import 'provider.dart';
import 'runtime_client.dart';
import 'safe_rebuild.dart';
import 'snapshot.dart';

/// Builder callback for [ConvexQuery].
typedef ConvexQueryWidgetBuilder<T> =
    Widget Function(BuildContext context, ConvexQuerySnapshot<T> snapshot);

/// Widget that subscribes to a Convex query and rebuilds from its snapshot.
///
/// Changing [query], [args] (compared deeply) or the client resubscribes.
/// Changing only the query or args keeps the previous data visible with
/// `isRefreshing: true` until the new result arrives; changing the client
/// (directly or through [ConvexProvider]) resets to the loading state, so one
/// client's results are never shown for another client.
///
/// When another widget already holds a live subscription to the same query
/// and arguments on a [ConvexClientRuntime], the first frame renders that
/// result instead of a loading frame.
class ConvexQuery<T> extends StatefulWidget {
  /// Creates a [ConvexQuery].
  const ConvexQuery({
    super.key,
    required this.query,
    required this.builder,
    this.args = const <String, dynamic>{},
    this.decode,
    this.client,
  });

  /// Convex query name to subscribe to.
  final String query;

  /// Query arguments passed to the runtime client.
  final Map<String, dynamic> args;

  /// Optional decoder for the raw query result.
  ///
  /// A decoder failure surfaces as a [ConvexDecodeException] in
  /// `snapshot.error`. The decoder is not part of the subscription identity:
  /// passing a new function (for example an inline closure on every parent
  /// rebuild) never resubscribes, but re-decodes the latest result. Prefer a
  /// stable reference (a tear-off or top-level function) when decoding is
  /// expensive and the parent rebuilds often.
  final ConvexDecoder<T>? decode;

  /// Optional runtime client override.
  final ConvexRuntimeClient? client;

  /// Builder that receives the latest query snapshot.
  final ConvexQueryWidgetBuilder<T> builder;

  @override
  State<ConvexQuery<T>> createState() => _ConvexQueryState<T>();
}

class _ConvexQueryState<T> extends State<ConvexQuery<T>>
    with ConvexSafeRebuild<ConvexQuery<T>> {
  static const DeepCollectionEquality _argsEquality = DeepCollectionEquality();

  ConvexRuntimeClient? _runtimeClient;
  ConvexRuntimeSubscription? _runtimeSubscription;
  StreamSubscription<ConvexRuntimeQueryEvent>? _eventSubscription;
  ConvexQuerySnapshot<T> _snapshot = ConvexQuerySnapshot<T>.initial();
  ConvexRuntimeQueryEvent? _lastEvent;
  Map<String, dynamic>? _subscribedArgs;
  int _subscriptionGeneration = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final resolvedClient = _resolveClient();
    final previousClient = _runtimeClient;
    final clientChanged =
        previousClient != null && previousClient != resolvedClient;
    if (previousClient != resolvedClient || _runtimeSubscription == null) {
      _subscribe(
        resolvedClient,
        preserveData: !clientChanged && _snapshot.hasData,
      );
    }
  }

  @override
  void didUpdateWidget(covariant ConvexQuery<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final resolvedClient = _resolveClient();
    final clientChanged = _runtimeClient != resolvedClient;
    final queryChanged = oldWidget.query != widget.query;
    final argsChanged = !_argsEquality.equals(_subscribedArgs, widget.args);
    if (clientChanged || queryChanged || argsChanged) {
      // Stale-while-revalidate only on the same client: a client swap (for
      // example a different user's runtime) must not keep showing the
      // previous client's data next to the new client's loading or error.
      _subscribe(
        resolvedClient,
        preserveData: !clientChanged && _snapshot.hasData,
      );
    } else if (oldWidget.decode != widget.decode) {
      // The decoder is a render-time mapping, not part of the subscription
      // identity — an inline closure differs on every parent rebuild, and
      // resubscribing would churn the query. Re-decode the latest event so
      // the snapshot reflects the new decoder; a build is already pending.
      final lastEvent = _lastEvent;
      if (lastEvent != null) {
        _snapshot = _snapshotFor(lastEvent);
      }
    }
  }

  @override
  void dispose() {
    _cancelSubscription();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _snapshot);
  }

  void _cancelSubscription() {
    _subscriptionGeneration += 1;
    unawaited(_eventSubscription?.cancel());
    _eventSubscription = null;
    _runtimeSubscription?.cancel();
    _runtimeSubscription = null;
  }

  T _decode(dynamic value) {
    final decoder = widget.decode;
    if (decoder != null) {
      return decoder(value);
    }
    return value as T;
  }

  void _handleEvent(ConvexRuntimeQueryEvent event) {
    if (!mounted) {
      return;
    }
    // Core streams are synchronous: this can run during a build or layout
    // pass (for example when a descendant's call makes the client emit).
    applyAndRebuild(() {
      _snapshot = _snapshotFor(event);
    });
  }

  /// The snapshot after [event]; records it as the latest event.
  ConvexQuerySnapshot<T> _snapshotFor(ConvexRuntimeQueryEvent event) {
    _lastEvent = event;
    switch (event) {
      case ConvexRuntimeQuerySuccess(:final value):
        try {
          final decoded = _decode(value);
          return ConvexQuerySnapshot<T>(
            data: decoded,
            error: null,
            isLoading: false,
            isRefreshing: false,
            hasData: true,
            hasError: false,
            source: event.source,
            hasPendingWrites: event.hasPendingWrites,
          );
        } catch (error, stackTrace) {
          return _snapshot.copyWith(
            error: ConvexDecodeException(error, stackTrace, value: value),
            isLoading: false,
            isRefreshing: false,
            hasError: true,
            source: event.source,
            hasPendingWrites: event.hasPendingWrites,
          );
        }
      case ConvexRuntimeQueryLoading():
        return ConvexQuerySnapshot<T>(
          data: null,
          error: null,
          isLoading: true,
          isRefreshing: false,
          hasData: false,
          hasError: false,
          source: event.source,
          hasPendingWrites: event.hasPendingWrites,
        );
      case ConvexRuntimeQueryError(:final error):
        return _snapshot.copyWith(
          error: error,
          isLoading: false,
          isRefreshing: false,
          hasError: true,
          source: event.source,
          hasPendingWrites: event.hasPendingWrites,
        );
    }
  }

  ConvexRuntimeClient _resolveClient() {
    return widget.client ?? ConvexProvider.of(context);
  }

  /// Resubscribes. Only called from lifecycle callbacks, which are always
  /// followed by a build, so state is assigned directly.
  void _subscribe(
    ConvexRuntimeClient resolvedClient, {
    required bool preserveData,
  }) {
    _cancelSubscription();
    _runtimeClient = resolvedClient;
    _lastEvent = null;
    _snapshot = ConvexQuerySnapshot<T>(
      data: preserveData && _snapshot.hasData ? _snapshot.data : null,
      error: null,
      isLoading: !preserveData,
      isRefreshing: preserveData,
      hasData: preserveData && _snapshot.hasData,
      hasError: false,
      source: preserveData ? _snapshot.source : ConvexQuerySource.unknown,
      hasPendingWrites: preserveData ? _snapshot.hasPendingWrites : false,
    );
    final generation = ++_subscriptionGeneration;
    final ConvexRuntimeSubscription subscription;
    try {
      final argsSnapshot = snapshotConvexArgs(widget.args);
      _subscribedArgs = argsSnapshot;
      subscription = resolvedClient.subscribe(widget.query, argsSnapshot);
    } catch (error) {
      // A disposed client (or unsupported argument values) throws
      // synchronously. Surface it as an error snapshot instead of an
      // ErrorWidget; with no live subscription, the next dependency or client
      // change retries.
      _snapshot = _snapshot.copyWith(
        error: error,
        isLoading: false,
        isRefreshing: false,
        hasError: true,
      );
      return;
    }
    _runtimeSubscription = subscription;
    if (subscription is ConvexSeededSubscription) {
      final seed = (subscription as ConvexSeededSubscription).currentEvent;
      if (seed != null) {
        _snapshot = _snapshotFor(seed);
      }
    }
    _eventSubscription = subscription.stream.listen(
      (event) {
        if (generation != _subscriptionGeneration) {
          return;
        }
        _handleEvent(event);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (generation != _subscriptionGeneration) {
          return;
        }
        _handleEvent(ConvexRuntimeQueryError(error, stackTrace: stackTrace));
      },
    );
  }
}
