import 'package:dartvex/dartvex.dart' show ConnectionStatus;
import 'package:flutter/widgets.dart';

import 'provider.dart';
import 'runtime_client.dart';

/// Builder callback for [ConvexConnectionBuilder].
typedef ConvexConnectionWidgetBuilder =
    Widget Function(BuildContext context, ConvexConnectionState state);

/// Builder callback for [ConvexConnectionStatusBuilder].
typedef ConvexConnectionStatusWidgetBuilder =
    Widget Function(BuildContext context, ConnectionStatus status);

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

/// Widget that rebuilds when the rich Convex [ConnectionStatus] changes.
///
/// Use this when the UI needs the detailed status — inflight counts, retry
/// count, loading, `hasEverConnected` — for example a connection/diagnostics
/// panel. For the coarse connected/connecting/disconnected case prefer
/// [ConvexConnectionBuilder].
class ConvexConnectionStatusBuilder extends StatelessWidget {
  /// Creates a [ConvexConnectionStatusBuilder].
  const ConvexConnectionStatusBuilder({
    super.key,
    required this.builder,
    this.client,
  });

  /// Optional runtime client override.
  final ConvexRuntimeClient? client;

  /// Builder that receives the latest rich connection status.
  final ConvexConnectionStatusWidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final runtimeClient = client ?? ConvexProvider.of(context);
    return StreamBuilder<ConnectionStatus>(
      stream: runtimeClient.connectionStatus,
      initialData: runtimeClient.currentConnectionStatus,
      builder: (context, snapshot) {
        final status = snapshot.data ?? runtimeClient.currentConnectionStatus;
        return builder(context, status);
      },
    );
  }
}
