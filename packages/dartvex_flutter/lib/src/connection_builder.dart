import 'package:flutter/widgets.dart';

import 'provider.dart';
import 'runtime_client.dart';

typedef ConvexConnectionWidgetBuilder = Widget Function(
    BuildContext context, ConvexConnectionState state);

class ConvexConnectionBuilder extends StatelessWidget {
  const ConvexConnectionBuilder({
    super.key,
    required this.builder,
    this.client,
  });

  final ConvexRuntimeClient? client;
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
