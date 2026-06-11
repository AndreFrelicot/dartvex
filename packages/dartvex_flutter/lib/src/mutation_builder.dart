import 'dart:async';

import 'package:dartvex/dartvex.dart' show OptimisticUpdate;
import 'package:flutter/widgets.dart';

import 'provider.dart';
import 'runtime_client.dart';
import 'snapshot.dart';

/// Builder callback for [ConvexMutation].
typedef ConvexMutationBuilder<T> = Widget Function(
  BuildContext context,
  ConvexRequestExecutor<T> mutate,
  ConvexRequestSnapshot<T> snapshot,
);

/// Widget that exposes an imperative Convex mutation and request snapshot.
class ConvexMutation<T> extends StatefulWidget {
  /// Creates a [ConvexMutation].
  const ConvexMutation({
    super.key,
    required this.mutation,
    required this.builder,
    this.decode,
    this.client,
    this.optimisticUpdate,
  });

  /// Convex mutation name to invoke.
  final String mutation;

  /// Optional decoder for the raw mutation result.
  final ConvexDecoder<T>? decode;

  /// Optional runtime client override.
  final ConvexRuntimeClient? client;

  /// Optional optimistic update applied while the mutation is in flight.
  ///
  /// Overlays query results locally the moment the mutation is sent and rolls
  /// back automatically when it completes or fails. See `ConvexClient.mutate`.
  final OptimisticUpdate? optimisticUpdate;

  /// Builder that receives the mutate callback and current request snapshot.
  final ConvexMutationBuilder<T> builder;

  @override
  State<ConvexMutation<T>> createState() => _ConvexMutationState<T>();
}

class _ConvexMutationState<T> extends State<ConvexMutation<T>> {
  ConvexRuntimeClient? _runtimeClient;
  ConvexRequestSnapshot<T> _snapshot = ConvexRequestSnapshot<T>.initial();
  Future<T>? _inFlight;
  int _requestGeneration = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final resolvedClient = widget.client ?? ConvexProvider.of(context);
    if (_runtimeClient == null) {
      _runtimeClient = resolvedClient;
      return;
    }
    if (_runtimeClient != resolvedClient) {
      _runtimeClient = resolvedClient;
      _invalidateRequestState();
    }
  }

  @override
  void didUpdateWidget(covariant ConvexMutation<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final resolvedClient = widget.client ?? ConvexProvider.of(context);
    // decode and optimisticUpdate are captured per request, not part of the
    // mutation identity — inline closures differ on every parent rebuild and
    // must not wipe the snapshot or orphan an in-flight request.
    final identityChanged = oldWidget.mutation != widget.mutation ||
        _runtimeClient != resolvedClient;
    _runtimeClient = resolvedClient;
    if (identityChanged) {
      _invalidateRequestState();
    }
  }

  @override
  void dispose() {
    _requestGeneration += 1;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _mutate, _snapshot);
  }

  T _decode(dynamic value, ConvexDecoder<T>? decoder) {
    if (decoder != null) {
      return decoder(value);
    }
    return value as T;
  }

  Future<T> _mutate([Map<String, dynamic> args = const <String, dynamic>{}]) {
    final active = _inFlight;
    if (active != null) {
      // ignore() keeps an ignored return value (the normal builder pattern,
      // where the snapshot carries the state) from surfacing as an unhandled
      // zone error; awaiting callers still receive the StateError.
      final rejection = Future<T>.error(
        StateError('Mutation "${widget.mutation}" is already in progress.'),
      );
      rejection.ignore();
      return rejection;
    }
    final completer = Completer<T>();
    _inFlight = completer.future;
    final generation = ++_requestGeneration;
    final runtimeClient = _runtimeClient!;
    final mutationName = widget.mutation;
    final decoder = widget.decode;
    final optimisticUpdate = widget.optimisticUpdate;
    setState(() {
      _snapshot = _snapshot.copyWith(
        error: null,
        isLoading: true,
        hasError: false,
      );
    });

    () async {
      try {
        final raw = await runtimeClient.mutate(
          mutationName,
          args,
          optimisticUpdate,
        );
        final decoded = _decode(raw, decoder);
        if (mounted && generation == _requestGeneration) {
          setState(() {
            _snapshot = ConvexRequestSnapshot<T>(
              data: decoded,
              error: null,
              isLoading: false,
              hasData: true,
              hasError: false,
            );
          });
        }
        completer.complete(decoded);
      } catch (error, stackTrace) {
        if (mounted && generation == _requestGeneration) {
          setState(() {
            _snapshot = _snapshot.copyWith(
              error: error,
              isLoading: false,
              hasError: true,
            );
          });
        }
        completer.completeError(error, stackTrace);
      } finally {
        if (generation == _requestGeneration) {
          _inFlight = null;
        }
      }
    }();

    return completer.future;
  }

  void _invalidateRequestState() {
    _requestGeneration += 1;
    _inFlight = null;
    if (!mounted) {
      return;
    }
    setState(() {
      _snapshot = ConvexRequestSnapshot<T>.initial();
    });
  }
}
