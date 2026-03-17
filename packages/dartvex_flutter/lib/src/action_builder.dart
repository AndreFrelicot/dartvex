import 'dart:async';

import 'package:flutter/widgets.dart';

import 'provider.dart';
import 'runtime_client.dart';
import 'snapshot.dart';

typedef ConvexActionBuilder<T> = Widget Function(
  BuildContext context,
  ConvexRequestExecutor<T> action,
  ConvexRequestSnapshot<T> snapshot,
);

class ConvexAction<T> extends StatefulWidget {
  const ConvexAction({
    super.key,
    required this.action,
    required this.builder,
    this.decode,
    this.client,
  });

  final String action;
  final ConvexDecoder<T>? decode;
  final ConvexRuntimeClient? client;
  final ConvexActionBuilder<T> builder;

  @override
  State<ConvexAction<T>> createState() => _ConvexActionState<T>();
}

class _ConvexActionState<T> extends State<ConvexAction<T>> {
  ConvexRuntimeClient? _runtimeClient;
  ConvexRequestSnapshot<T> _snapshot = ConvexRequestSnapshot<T>.initial();
  Future<T>? _inFlight;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _runtimeClient = widget.client ?? ConvexProvider.of(context);
  }

  @override
  void didUpdateWidget(covariant ConvexAction<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      _runtimeClient = widget.client ?? ConvexProvider.of(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _runAction, _snapshot);
  }

  T _decode(dynamic value) {
    final decoder = widget.decode;
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
      throw StateError('Action "${widget.action}" is already in progress.');
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
        final raw = await _runtimeClient!.action(widget.action, args);
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
