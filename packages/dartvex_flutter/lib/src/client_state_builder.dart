import 'dart:async';

import 'package:flutter/widgets.dart';

import 'safe_rebuild.dart';

/// Rebuilds from a client's state stream, seeded from the client's current
/// value.
///
/// Used by the auth and connection builders instead of a bare `StreamBuilder`:
///
/// * When [client] changes (compared with `==`), the state resubscribes and
///   re-seeds from [current]. `StreamBuilder` keeps the previous stream's last
///   value across a stream swap, and the core streams do not replay, so a
///   swapped-in client would otherwise keep showing the old client's auth or
///   connection state until it happens to emit.
/// * Events delivered synchronously during a build or layout pass rebuild
///   after the frame instead of throwing (see [ConvexSafeRebuild]).
class ClientStateBuilder<C extends Object, T> extends StatefulWidget {
  /// Creates a client state builder.
  const ClientStateBuilder({
    super.key,
    required this.client,
    required this.stream,
    required this.current,
    required this.builder,
  });

  /// Identity of the client the stream belongs to.
  final C client;

  /// Reads the state stream of [client].
  final Stream<T> Function(C client) stream;

  /// Reads the current state of [client].
  final T Function(C client) current;

  /// Builds the widget for the latest state.
  final Widget Function(BuildContext context, T value) builder;

  @override
  State<ClientStateBuilder<C, T>> createState() =>
      _ClientStateBuilderState<C, T>();
}

class _ClientStateBuilderState<C extends Object, T>
    extends State<ClientStateBuilder<C, T>>
    with ConvexSafeRebuild<ClientStateBuilder<C, T>> {
  StreamSubscription<T>? _subscription;
  late T _value;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant ClientStateBuilder<C, T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      unawaited(_subscription?.cancel());
      _subscribe();
    }
  }

  void _subscribe() {
    final client = widget.client;
    _value = widget.current(client);
    _subscription = widget.stream(client).listen(
      (value) {
        if (widget.client != client) {
          return;
        }
        applyAndRebuild(() => _value = value);
      },
      // Errors on these state streams carry no state; keep the last value.
      onError: (Object _) {},
    );
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}
