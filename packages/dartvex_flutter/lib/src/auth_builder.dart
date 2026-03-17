import 'package:dartvex/dartvex.dart';
import 'package:flutter/widgets.dart';

import 'auth_provider.dart';

typedef ConvexAuthWidgetBuilder<TUser> = Widget Function(
    BuildContext context, AuthState<TUser> state);

class ConvexAuthBuilder<TUser> extends StatelessWidget {
  const ConvexAuthBuilder({
    super.key,
    required this.builder,
    this.client,
  });

  final ConvexAuthClient<TUser>? client;
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
