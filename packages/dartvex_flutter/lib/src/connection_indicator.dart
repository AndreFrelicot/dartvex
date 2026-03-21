import 'package:flutter/widgets.dart';

import 'connection_builder.dart';
import 'runtime_client.dart';

/// Builder used by [ConvexConnectionIndicator] for a specific connection state.
typedef ConvexConnectionIndicatorBuilder = Widget Function(
    BuildContext context);

/// Widget that switches between builders for connected and disconnected states.
class ConvexConnectionIndicator extends StatelessWidget {
  /// Creates a [ConvexConnectionIndicator].
  const ConvexConnectionIndicator({
    super.key,
    required this.connectedBuilder,
    required this.connectingBuilder,
    required this.disconnectedBuilder,
    this.client,
  });

  /// Optional runtime client override.
  final ConvexRuntimeClient? client;

  /// Builder used when the client is connected.
  final ConvexConnectionIndicatorBuilder connectedBuilder;

  /// Builder used while connecting or reconnecting.
  final ConvexConnectionIndicatorBuilder connectingBuilder;

  /// Builder used when the client is disconnected.
  final ConvexConnectionIndicatorBuilder disconnectedBuilder;

  @override
  Widget build(BuildContext context) {
    return ConvexConnectionBuilder(
      client: client,
      builder: (context, state) {
        switch (state) {
          case ConvexConnectionState.connected:
            return connectedBuilder(context);
          case ConvexConnectionState.connecting:
          case ConvexConnectionState.reconnecting:
            return connectingBuilder(context);
          case ConvexConnectionState.disconnected:
            return disconnectedBuilder(context);
        }
      },
    );
  }
}
