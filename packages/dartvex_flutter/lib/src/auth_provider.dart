import 'package:dartvex/dartvex.dart';
import 'package:flutter/widgets.dart';

class ConvexAuthProvider<TUser> extends StatefulWidget {
  const ConvexAuthProvider({
    super.key,
    required this.client,
    required this.child,
    this.disposeClient = false,
  });

  final ConvexAuthClient<TUser> client;
  final Widget child;
  final bool disposeClient;

  static ConvexAuthClient<TUser> of<TUser>(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_ConvexAuthProviderScope<TUser>>();
    if (scope == null) {
      throw FlutterError(
        'ConvexAuthProvider.of<$TUser>() called with no matching '
        'ConvexAuthProvider<$TUser> in the widget tree.\n'
        'Wrap your subtree in ConvexAuthProvider before using Convex auth widgets.',
      );
    }
    return scope.client;
  }

  static ConvexAuthClient<TUser>? maybeOf<TUser>(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_ConvexAuthProviderScope<TUser>>();
    return scope?.client;
  }

  @override
  State<ConvexAuthProvider<TUser>> createState() =>
      _ConvexAuthProviderState<TUser>();
}

class _ConvexAuthProviderState<TUser> extends State<ConvexAuthProvider<TUser>> {
  @override
  void didUpdateWidget(covariant ConvexAuthProvider<TUser> oldWidget) {
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
    return _ConvexAuthProviderScope<TUser>(
      client: widget.client,
      child: widget.child,
    );
  }
}

class _ConvexAuthProviderScope<TUser> extends InheritedWidget {
  const _ConvexAuthProviderScope({
    required this.client,
    required super.child,
  });

  final ConvexAuthClient<TUser> client;

  @override
  bool updateShouldNotify(covariant _ConvexAuthProviderScope<TUser> oldWidget) {
    return oldWidget.client != client;
  }
}
