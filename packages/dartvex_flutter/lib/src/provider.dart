import 'package:flutter/widgets.dart';

import 'runtime_client.dart';

class ConvexProvider extends StatefulWidget {
  const ConvexProvider({
    super.key,
    required this.client,
    required this.child,
    this.disposeClient = false,
  });

  final ConvexRuntimeClient client;
  final Widget child;
  final bool disposeClient;

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

  static ConvexRuntimeClient? maybeOf(BuildContext context) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<_ConvexProviderScope>();
    return scope?.client;
  }

  @override
  State<ConvexProvider> createState() => _ConvexProviderState();
}

class _ConvexProviderState extends State<ConvexProvider> {
  @override
  void didUpdateWidget(covariant ConvexProvider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client && oldWidget.disposeClient) {
      oldWidget.client.dispose();
    }
  }

  @override
  void dispose() {
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
