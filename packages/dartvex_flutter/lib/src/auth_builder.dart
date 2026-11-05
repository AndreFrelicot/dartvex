import 'package:dartvex/dartvex.dart';
import 'package:flutter/widgets.dart';

import 'auth_provider.dart';
import 'client_state_builder.dart';

/// Builder callback for [ConvexAuthBuilder].
typedef ConvexAuthWidgetBuilder<TUser> =
    Widget Function(BuildContext context, AuthState<TUser> state);

/// Widget that rebuilds when the current authentication state changes.
///
/// Swapping the auth client (directly or through [ConvexAuthProvider])
/// re-seeds the state from the new client's `currentAuthState`, so a fresh
/// signed-out client never inherits the previous client's signed-in state.
class ConvexAuthBuilder<TUser> extends StatelessWidget {
  /// Creates a [ConvexAuthBuilder].
  const ConvexAuthBuilder({super.key, required this.builder, this.client});

  /// Optional auth client override.
  final ConvexAuthClient<TUser>? client;

  /// Builder that receives the latest auth state.
  final ConvexAuthWidgetBuilder<TUser> builder;

  @override
  Widget build(BuildContext context) {
    final authClient = client ?? ConvexAuthProvider.of<TUser>(context);
    return ClientStateBuilder<ConvexAuthClient<TUser>, AuthState<TUser>>(
      client: authClient,
      stream: (client) => client.authState,
      current: (client) => client.currentAuthState,
      builder: builder,
    );
  }
}
