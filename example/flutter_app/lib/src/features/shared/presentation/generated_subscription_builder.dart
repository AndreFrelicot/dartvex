import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../../../convex_api/runtime.dart';

typedef TypedSubscriptionFactory<T> = TypedConvexSubscription<T> Function();
typedef TypedSubscriptionWidgetBuilder<T> =
    Widget Function(
      BuildContext context,
      TypedSubscriptionSnapshot<T> snapshot,
    );

class TypedSubscriptionSnapshot<T> {
  const TypedSubscriptionSnapshot({
    required this.data,
    required this.error,
    required this.isLoading,
  });

  const TypedSubscriptionSnapshot.loading()
    : data = null,
      error = null,
      isLoading = true;

  final T? data;
  final String? error;
  final bool isLoading;

  bool get hasData => data != null;
  bool get hasError => error != null;
}

class GeneratedSubscriptionBuilder<T> extends StatefulWidget {
  const GeneratedSubscriptionBuilder({
    super.key,
    required this.subscriptionKey,
    required this.subscribe,
    required this.builder,
  });

  final Object subscriptionKey;
  final TypedSubscriptionFactory<T> subscribe;
  final TypedSubscriptionWidgetBuilder<T> builder;

  @override
  State<GeneratedSubscriptionBuilder<T>> createState() =>
      _GeneratedSubscriptionBuilderState<T>();
}

class _GeneratedSubscriptionBuilderState<T>
    extends State<GeneratedSubscriptionBuilder<T>> {
  TypedConvexSubscription<T>? _subscription;
  StreamSubscription<TypedQueryResult<T>>? _streamSubscription;
  TypedSubscriptionSnapshot<T> _snapshot =
      TypedSubscriptionSnapshot<T>.loading();

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant GeneratedSubscriptionBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.subscriptionKey != widget.subscriptionKey) {
      _subscribe();
    }
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _snapshot);
  }

  void _cancel() {
    unawaited(_streamSubscription?.cancel());
    _streamSubscription = null;
    _subscription?.cancel();
    _subscription = null;
  }

  void _subscribe() {
    _cancel();
    final previousData = _snapshot.data;
    setState(() {
      _snapshot = TypedSubscriptionSnapshot<T>(
        data: previousData,
        error: null,
        isLoading: previousData == null,
      );
    });

    final subscription = widget.subscribe();
    _subscription = subscription;
    _streamSubscription = subscription.stream.listen((event) {
      if (!mounted) {
        return;
      }
      switch (event) {
        case TypedQuerySuccess(:final value):
          setState(() {
            _snapshot = TypedSubscriptionSnapshot<T>(
              data: value,
              error: null,
              isLoading: false,
            );
          });
        case TypedQueryError(:final message):
          setState(() {
            _snapshot = TypedSubscriptionSnapshot<T>(
              data: _snapshot.data,
              error: message,
              isLoading: false,
            );
          });
      }
    });
  }
}
