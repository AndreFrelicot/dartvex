import 'package:flutter/widgets.dart';

import 'connection_builder.dart';
import 'runtime_client.dart';

typedef ConvexConnectionIndicatorBuilder = Widget Function(
    BuildContext context);

class ConvexConnectionIndicator extends StatelessWidget {
  const ConvexConnectionIndicator({
    super.key,
    required this.connectedBuilder,
    required this.connectingBuilder,
    required this.disconnectedBuilder,
    this.client,
  });

  final ConvexRuntimeClient? client;
  final ConvexConnectionIndicatorBuilder connectedBuilder;
  final ConvexConnectionIndicatorBuilder connectingBuilder;
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
