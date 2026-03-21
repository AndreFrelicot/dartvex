import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';

import 'provider.dart';
import 'runtime_client.dart';
import 'snapshot.dart';

/// Builder callback for [ConvexQuery].
typedef ConvexQueryWidgetBuilder<T> = Widget Function(
    BuildContext context, ConvexQuerySnapshot<T> snapshot);

/// Widget that subscribes to a Convex query and rebuilds from its snapshot.
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
  final ConvexDecoder<T>? decode;

  /// Optional runtime client override.
  final ConvexRuntimeClient? client;

  /// Builder that receives the latest query snapshot.
  final ConvexQueryWidgetBuilder<T> builder;

  @override
  State<ConvexQuery<T>> createState() => _ConvexQueryState<T>();
}

class _ConvexQueryState<T> extends State<ConvexQuery<T>> {
  static const DeepCollectionEquality _argsEquality = DeepCollectionEquality();

  ConvexRuntimeClient? _runtimeClient;
  ConvexRuntimeSubscription? _runtimeSubscription;
  StreamSubscription<ConvexRuntimeQueryEvent>? _eventSubscription;
  ConvexQuerySnapshot<T> _snapshot = ConvexQuerySnapshot<T>.initial();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final resolvedClient = _resolveClient();
    if (_runtimeClient != resolvedClient || _runtimeSubscription == null) {
      _subscribe(resolvedClient, preserveData: _snapshot.hasData);
    }
  }

  @override
  void didUpdateWidget(covariant ConvexQuery<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final resolvedClient = _resolveClient();
    final clientChanged = _runtimeClient != resolvedClient;
    final queryChanged = oldWidget.query != widget.query;
    final argsChanged = !_argsEquality.equals(oldWidget.args, widget.args);
    final decodeChanged = oldWidget.decode != widget.decode;
    if (clientChanged || queryChanged || argsChanged || decodeChanged) {
      _subscribe(resolvedClient, preserveData: _snapshot.hasData);
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
    switch (event) {
      case ConvexRuntimeQuerySuccess(:final value):
        try {
          final decoded = _decode(value);
          setState(() {
            _snapshot = ConvexQuerySnapshot<T>(
              data: decoded,
              error: null,
              isLoading: false,
              isRefreshing: false,
              hasData: true,
              hasError: false,
              source: event.source,
              hasPendingWrites: event.hasPendingWrites,
            );
          });
        } catch (error, stackTrace) {
          setState(() {
            _snapshot = _snapshot.copyWith(
              error: _DecodeException(error, stackTrace),
              isLoading: false,
              isRefreshing: false,
              hasError: true,
              source: event.source,
              hasPendingWrites: event.hasPendingWrites,
            );
          });
        }
      case ConvexRuntimeQueryError(:final error):
        setState(() {
          _snapshot = _snapshot.copyWith(
            error: error,
            isLoading: false,
            isRefreshing: false,
            hasError: true,
            source: event.source,
            hasPendingWrites: event.hasPendingWrites,
          );
        });
    }
  }

  ConvexRuntimeClient _resolveClient() {
    return widget.client ?? ConvexProvider.of(context);
  }

  void _subscribe(
    ConvexRuntimeClient resolvedClient, {
    required bool preserveData,
  }) {
    _cancelSubscription();
    _runtimeClient = resolvedClient;
    if (mounted) {
      setState(() {
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
      });
    }
    final subscription = resolvedClient.subscribe(widget.query, widget.args);
    _runtimeSubscription = subscription;
    _eventSubscription = subscription.stream.listen(_handleEvent);
  }
}

class _DecodeException implements Exception {
  const _DecodeException(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;

  @override
  String toString() => error.toString();
}
