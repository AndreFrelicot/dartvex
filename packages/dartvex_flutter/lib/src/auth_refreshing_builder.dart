import 'package:flutter/widgets.dart';

import 'provider.dart';
import 'runtime_client.dart';

/// Builder callback for [ConvexAuthRefreshingBuilder].
typedef ConvexAuthRefreshingWidgetBuilder =
    Widget Function(BuildContext context, bool isRefreshing);

/// Widget that rebuilds when the Convex auth-refreshing state changes.
///
/// `isRefreshing` is `true` while the client recovers auth after a server
/// rejection — the socket is briefly stopped while a fresh token is fetched —
/// and `false` once that token is confirmed. Use it to show an
/// "authenticating…" affordance without surfacing the brief disconnect as a
/// lost connection. Backed by `ConvexClient.authRefreshing`.
class ConvexAuthRefreshingBuilder extends StatelessWidget {
  /// Creates a [ConvexAuthRefreshingBuilder].
  const ConvexAuthRefreshingBuilder({
    super.key,
    required this.builder,
    this.client,
  });

  /// Optional runtime client override.
  final ConvexRuntimeClient? client;

  /// Builder that receives the latest auth-refreshing state.
  final ConvexAuthRefreshingWidgetBuilder builder;

  @override
  Widget build(BuildContext context) {
    final runtimeClient = client ?? ConvexProvider.of(context);
    return StreamBuilder<bool>(
      stream: runtimeClient.authRefreshing,
      initialData: runtimeClient.currentAuthRefreshing,
      builder: (context, snapshot) {
        final isRefreshing =
            snapshot.data ?? runtimeClient.currentAuthRefreshing;
        return builder(context, isRefreshing);
      },
    );
  }
}
