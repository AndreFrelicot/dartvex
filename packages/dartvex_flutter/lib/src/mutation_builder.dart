import 'dart:async';

import 'package:flutter/widgets.dart';

import 'provider.dart';
import 'runtime_client.dart';
import 'snapshot.dart';

typedef ConvexMutationBuilder<T> = Widget Function(
  BuildContext context,
  ConvexRequestExecutor<T> mutate,
  ConvexRequestSnapshot<T> snapshot,
);

class ConvexMutation<T> extends StatefulWidget {
  const ConvexMutation({
    super.key,
    required this.mutation,
    required this.builder,
    this.decode,
    this.client,
  });

  final String mutation;
  final ConvexDecoder<T>? decode;
  final ConvexRuntimeClient? client;
  final ConvexMutationBuilder<T> builder;

  @override
  State<ConvexMutation<T>> createState() => _ConvexMutationState<T>();
}

class _ConvexMutationState<T> extends State<ConvexMutation<T>> {
  ConvexRuntimeClient? _runtimeClient;
  ConvexRequestSnapshot<T> _snapshot = ConvexRequestSnapshot<T>.initial();
  Future<T>? _inFlight;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _runtimeClient = widget.client ?? ConvexProvider.of(context);
  }

  @override
  void didUpdateWidget(covariant ConvexMutation<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      _runtimeClient = widget.client ?? ConvexProvider.of(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _mutate, _snapshot);
  }

  T _decode(dynamic value) {
    final decoder = widget.decode;
    if (decoder != null) {
      return decoder(value);
    }
    return value as T;
  }

  Future<T> _mutate([Map<String, dynamic> args = const <String, dynamic>{}]) {
    final active = _inFlight;
    if (active != null) {
      throw StateError('Mutation "${widget.mutation}" is already in progress.');
    }
    final completer = Completer<T>();
    _inFlight = completer.future;
    setState(() {
      _snapshot = _snapshot.copyWith(
        error: null,
        isLoading: true,
        hasError: false,
      );
    });

    () async {
      try {
        final raw = await _runtimeClient!.mutate(widget.mutation, args);
        final decoded = _decode(raw);
        if (mounted) {
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
        if (mounted) {
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
        _inFlight = null;
      }
    }();

    return completer.future;
  }
}
