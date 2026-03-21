import 'package:dartvex/dartvex.dart';
import 'package:flutter/widgets.dart';

import 'auth_provider.dart';

/// Builder callback for [ConvexAuthBuilder].
typedef ConvexAuthWidgetBuilder<TUser> = Widget Function(
    BuildContext context, AuthState<TUser> state);

/// Widget that rebuilds when the current authentication state changes.
class ConvexAuthBuilder<TUser> extends StatelessWidget {
  /// Creates a [ConvexAuthBuilder].
  const ConvexAuthBuilder({
    super.key,
    required this.builder,
    this.client,
  });

  /// Optional auth client override.
  final ConvexAuthClient<TUser>? client;

  /// Builder that receives the latest auth state.
  final ConvexAuthWidgetBuilder<TUser> builder;

  @override
  Widget build(BuildContext context) {
    final authClient = client ?? ConvexAuthProvider.of<TUser>(context);
    return StreamBuilder<AuthState<TUser>>(
      stream: authClient.authState,
      initialData: authClient.currentAuthState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? authClient.currentAuthState;
        return builder(context, state);
      },
    );
  }
}
