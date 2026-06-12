import 'dart:async';

import 'package:flutter/widgets.dart';

import 'provider.dart';
import 'runtime_client.dart';
import 'snapshot.dart';

/// Builder callback for [ConvexAction].
typedef ConvexActionBuilder<T> = Widget Function(
  BuildContext context,
  ConvexRequestExecutor<T> action,
  ConvexRequestSnapshot<T> snapshot,
);

/// Widget that exposes an imperative Convex action and request snapshot to its child.
class ConvexAction<T> extends StatefulWidget {
  /// Creates a [ConvexAction].
  const ConvexAction({
    super.key,
    required this.action,
    required this.builder,
    this.decode,
    this.client,
  });

  /// Convex action name to invoke.
  final String action;

  /// Optional decoder for the raw action result.
  final ConvexDecoder<T>? decode;

  /// Optional runtime client override.
  final ConvexRuntimeClient? client;

  /// Builder that receives the action callback and current request snapshot.
  final ConvexActionBuilder<T> builder;

  @override
  State<ConvexAction<T>> createState() => _ConvexActionState<T>();
}

class _ConvexActionState<T> extends State<ConvexAction<T>> {
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
  void didUpdateWidget(covariant ConvexAction<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final resolvedClient = widget.client ?? ConvexProvider.of(context);
    // decode is captured per request, not part of the action identity — an
    // inline closure differs on every parent rebuild and must not wipe the
    // snapshot or orphan an in-flight request.
    final identityChanged =
        oldWidget.action != widget.action || _runtimeClient != resolvedClient;
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
    return widget.builder(context, _runAction, _snapshot);
  }

  T _decode(dynamic value, ConvexDecoder<T>? decoder) {
    if (decoder != null) {
      return decoder(value);
    }
    return value as T;
  }

  Future<T> _runAction([
    Map<String, dynamic> args = const <String, dynamic>{},
  ]) {
    final active = _inFlight;
    if (active != null) {
      // ignore() keeps an ignored return value (the normal builder pattern,
      // where the snapshot carries the state) from surfacing as an unhandled
      // zone error; awaiting callers still receive the StateError.
      final rejection = Future<T>.error(
        StateError('Action "${widget.action}" is already in progress.'),
      );
      rejection.ignore();
      return rejection;
    }
    final completer = Completer<T>();
    final future = completer.future;
    // The builder API intentionally lets callers ignore the returned future
    // and observe failures through the snapshot.
    future.ignore();
    _inFlight = future;
    final generation = ++_requestGeneration;
    final runtimeClient = _runtimeClient!;
    final actionName = widget.action;
    final decoder = widget.decode;
    setState(() {
      _snapshot = _snapshot.copyWith(
        error: null,
        isLoading: true,
        hasError: false,
      );
    });

    () async {
      try {
        final raw = await runtimeClient.action(actionName, args);
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

    return future;
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
