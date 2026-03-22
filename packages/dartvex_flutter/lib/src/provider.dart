import 'dart:async';

import 'package:flutter/widgets.dart';

import 'runtime_client.dart';

/// Inherited widget that provides a [ConvexRuntimeClient] to descendant widgets.
class ConvexProvider extends StatefulWidget {
  /// Creates a [ConvexProvider].
  const ConvexProvider({
    super.key,
    required this.client,
    required this.child,
    this.disposeClient = false,
  });

  /// Runtime client exposed to the widget subtree.
  final ConvexRuntimeClient client;

  /// Child widget subtree.
  final Widget child;

  /// Whether the provider should dispose [client] automatically.
  final bool disposeClient;

  /// Returns the nearest [ConvexRuntimeClient] from the widget tree.
  static ConvexRuntimeClient of(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<_ConvexProviderScope>();
    if (scope == null) {
      throw FlutterError(
        'ConvexProvider.of() called with no ConvexProvider in the widget tree.\n'
        'Wrap your subtree in ConvexProvider before using Convex widgets.',
      );
    }
    return scope.client;
  }

  /// Returns the nearest [ConvexRuntimeClient], or `null` if absent.
  static ConvexRuntimeClient? maybeOf(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<_ConvexProviderScope>();
    return scope?.client;
  }

  @override
  State<ConvexProvider> createState() => _ConvexProviderState();
}

class _ConvexProviderState extends State<ConvexProvider>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      final client = widget.client;
      if (client.currentConnectionState != ConvexConnectionState.connected) {
        unawaited(client.reconnectNow('AppResumed'));
      }
    }
  }

  @override
  void didUpdateWidget(covariant ConvexProvider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client && oldWidget.disposeClient) {
      oldWidget.client.dispose();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.disposeClient) {
      widget.client.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _ConvexProviderScope(client: widget.client, child: widget.child);
  }
}

class _ConvexProviderScope extends InheritedWidget {
  const _ConvexProviderScope({required this.client, required super.child});

  final ConvexRuntimeClient client;

  @override
  bool updateShouldNotify(covariant _ConvexProviderScope oldWidget) {
    return oldWidget.client != client;
  }
}
