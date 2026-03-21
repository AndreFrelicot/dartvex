import 'package:flutter/widgets.dart';

import 'provider.dart';
import 'runtime_client.dart';

/// Builder callback for [ConvexConnectionBuilder].
typedef ConvexConnectionWidgetBuilder = Widget Function(
    BuildContext context, ConvexConnectionState state);

/// Widget that rebuilds when the Convex connection state changes.
class ConvexConnectionBuilder extends StatelessWidget {
  /// Creates a [ConvexConnectionBuilder].
  const ConvexConnectionBuilder({
    super.key,
    required this.builder,
    this.client,
  });

  /// Optional runtime client override.
  final ConvexRuntimeClient? client;

  /// Builder that receives the latest connection state.
  final ConvexConnectionWidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final runtimeClient = client ?? ConvexProvider.of(context);
    return StreamBuilder<ConvexConnectionState>(
      stream: runtimeClient.connectionState,
      initialData: runtimeClient.currentConnectionState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? runtimeClient.currentConnectionState;
        return builder(context, state);
      },
    );
  }
}
