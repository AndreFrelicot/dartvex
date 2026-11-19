import 'package:dartvex_auth2_convex/dartvex_auth2_convex.dart';
import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:material_ui/material_ui.dart';

import '../../../../convex_api/api.dart';
import '../../../../convex_api/modules/users.dart' as users_api;
import '../../shared/presentation/concierge_design.dart';
import '../../shared/presentation/conversation_widgets.dart';
import '../../shared/presentation/generated_subscription_builder.dart';
import '../../shared/presentation/section_card.dart';
import '../data/convex_auth_demo.dart';

/// Auth panel shown when Convex Auth mode is active.
///
/// Signs up and signs in with the username/password method of
/// `@convex-dev/auth` v2 through `dartvex_auth2_convex`, then shows the
/// session the adapter keeps in sync with the client.
class ConvexAuthPanel extends StatefulWidget {
  const ConvexAuthPanel({
    super.key,
    required this.provider,
    required this.authClient,
    required this.store,
    this.api,
  });

  final ConvexAuthSessionProvider provider;
  final ConvexAuthClient<ConvexAuthSession>? authClient;
  final ConvexAuthSessionStore store;

  /// Typed bindings, used to show who the backend resolves the session to.
  final ConvexApi? api;

  @override
  State<ConvexAuthPanel> createState() => _ConvexAuthPanelState();
}

class _ConvexAuthPanelState extends State<ConvexAuthPanel>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  bool _isSignUp = true;
  bool _isLoading = false;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _run(
    Future<void> Function(ConvexAuthClient<ConvexAuthSession> authClient)
    operation,
  ) async {
    final authClient = widget.authClient;
    if (authClient == null) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await operation(authClient);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeConvexAuthError(error);
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _submit() => _run((authClient) async {
    final username = _usernameController.text.trim();
    final password = _passwordController.text;
    // The provider sends this request once, from login(), and forgets it:
    // the password is not kept after the call.
    widget.provider.signIn = _isSignUp
        ? ConvexAuthSignIn.usernamePasswordSignUp(
            username: username,
            password: password,
            function: ConvexAuthDemoFunctions.signUp,
          )
        : ConvexAuthSignIn.usernamePassword(
            username: username,
            password: password,
            function: ConvexAuthDemoFunctions.signIn,
          );
    await authClient.login();
    _passwordController.clear();
  });

  Future<void> _restore() => _run((authClient) async {
    await authClient.loginFromCache();
  });

  Future<void> _logout() => _run((authClient) async {
    await authClient.logout();
  });

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SectionCard(
      eyebrow: 'CONVEX AUTH',
      title: 'Convex Auth v2 Demo',
      subtitle:
          'Username and password sign-in with @convex-dev/auth. The session '
          'is a one-minute access token plus a refresh token that rotates on '
          'every refresh; dartvex_auth2_convex keeps both in sync.',
      trailing: const ThreadPill(
        label: 'Rotating sessions',
        backgroundColor: Color(0x1A00D1FF),
        foregroundColor: ConciergeColors.cyanSoft,
        icon: Icons.autorenew_rounded,
      ),
      child: ConvexAuthBuilder<ConvexAuthSession>(
        builder: (context, state) {
          final busy = _isLoading || state is AuthLoading<ConvexAuthSession>;
          return switch (state) {
            AuthAuthenticated<ConvexAuthSession>() => _SignedInContent(
              api: widget.api,
              store: widget.store,
              isLoading: busy,
              error: _error,
              onLogout: _logout,
            ),
            _ => _AuthForm(
              store: widget.store,
              usernameController: _usernameController,
              passwordController: _passwordController,
              isSignUp: _isSignUp,
              isLoading: busy,
              error: _error,
              onToggleMode: () => setState(() {
                _isSignUp = !_isSignUp;
                _error = null;
              }),
              onSubmit: _submit,
              onRestore: _restore,
            ),
          };
        },
      ),
    );
  }
}

class _AuthForm extends StatelessWidget {
  const _AuthForm({
    required this.store,
    required this.usernameController,
    required this.passwordController,
    required this.isSignUp,
    required this.isLoading,
    required this.error,
    required this.onToggleMode,
    required this.onSubmit,
    required this.onRestore,
  });

  final ConvexAuthSessionStore store;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final bool isSignUp;
  final bool isLoading;
  final String? error;
  final VoidCallback onToggleMode;
  final VoidCallback onSubmit;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InlineNotice(
          message: isSignUp
              ? 'Create an account with a username and a password. Convex '
                    'Auth stores the credentials in its own components; the '
                    'app only keeps a row in its users table.'
              : 'Sign in with your username and password.',
        ),
        const SizedBox(height: 16),
        TextField(
          key: const ValueKey<String>('convex-auth-username'),
          controller: usernameController,
          decoration: const InputDecoration(
            labelText: 'Username',
            hintText: 'ada',
          ),
          autocorrect: false,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey<String>('convex-auth-password'),
          controller: passwordController,
          decoration: const InputDecoration(
            labelText: 'Password',
            hintText: 'min 10 characters',
          ),
          obscureText: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => onSubmit(),
        ),
        if (error != null) ...<Widget>[
          const SizedBox(height: 12),
          InlineNotice(
            message: error!,
            backgroundColor: ConciergeColors.danger.withValues(alpha: 0.14),
            foregroundColor: ConciergeColors.danger,
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            FilledButton(
              onPressed: isLoading ? null : onSubmit,
              child: isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(isSignUp ? 'Sign Up' : 'Sign In'),
            ),
            // A saved session that is not live: the restore at startup failed
            // (offline, for example). Signing out forgets the saved session.
            ListenableBuilder(
              listenable: store,
              builder: (context, _) => store.session == null
                  ? const SizedBox.shrink()
                  : OutlinedButton(
                      onPressed: isLoading ? null : onRestore,
                      child: const Text('Restore Session'),
                    ),
            ),
            TextButton(
              onPressed: onToggleMode,
              child: Text(
                isSignUp
                    ? 'Already have an account? Sign in'
                    : 'Need an account? Sign up',
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SignedInContent extends StatelessWidget {
  const _SignedInContent({
    required this.api,
    required this.store,
    required this.isLoading,
    required this.error,
    required this.onLogout,
  });

  final ConvexApi? api;
  final ConvexAuthSessionStore store;
  final bool isLoading;
  final String? error;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            const _StatusPill(
              label: 'Auth: Signed in',
              backgroundColor: Color(0xFF0D3D37),
              foregroundColor: ConciergeColors.success,
            ),
            ConvexConnectionBuilder(
              builder: (context, connectionState) => _StatusPill(
                label: 'Realtime: ${connectionState.name}',
                backgroundColor:
                    connectionState == ConvexConnectionState.connected
                    ? const Color(0xFF0D3D37)
                    : const Color(0xFF2C1F5C),
                foregroundColor:
                    connectionState == ConvexConnectionState.connected
                    ? ConciergeColors.success
                    : ConciergeColors.cyan,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF0D3D37),
            borderRadius: BorderRadius.circular(22),
          ),
          // The store is what onSessionChanged saved last: it changes on
          // every refresh, while the auth state above keeps the same user.
          child: ListenableBuilder(
            listenable: store,
            builder: (context, _) {
              final session = store.session;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Convex Auth Session',
                    style: textTheme.labelLarge?.copyWith(
                      color: ConciergeColors.cyanSoft,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (session == null)
                    const Text('No saved session.')
                  else ...<Widget>[
                    SelectableText('userId: ${session.userId}'),
                    SelectableText(
                      'sessionId: ${session.sessionId ?? 'unknown'}',
                    ),
                    Text(
                      'refresh token valid until: '
                      '${_formatDateTime(session.refreshTokenExpiresAt)}',
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Token rotations: ${store.rotationCount}',
                      key: const ValueKey<String>('convex-auth-rotations'),
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        const InlineNotice(
          message:
              'The client refreshes the session before the access token '
              'expires, about once a minute: each refresh replaces both '
              'tokens, and the count above goes up. A real app saves the '
              'session to secure storage in onSessionChanged; this demo keeps '
              'it in memory.',
        ),
        if (api != null) ...<Widget>[
          const SizedBox(height: 12),
          _ServerViewer(api: api!),
        ],
        if (error != null) ...<Widget>[
          const SizedBox(height: 12),
          InlineNotice(
            message: error!,
            backgroundColor: ConciergeColors.danger.withValues(alpha: 0.14),
            foregroundColor: ConciergeColors.danger,
          ),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            OutlinedButton(
              onPressed: isLoading ? null : onLogout,
              child: const Text('Sign Out'),
            ),
          ],
        ),
      ],
    );
  }
}

/// What the backend makes of the token: `users:viewer` resolves the session
/// to its user with `getAuthUserId`.
class _ServerViewer extends StatelessWidget {
  const _ServerViewer({required this.api});

  final ConvexApi api;

  @override
  Widget build(BuildContext context) {
    return GeneratedSubscriptionBuilder<users_api.ViewerResult?>(
      subscriptionKey: api,
      subscribe: api.users.viewerSubscribe,
      builder: (context, snapshot) {
        if (snapshot.isLoading) {
          return const LinearProgressIndicator(minHeight: 2);
        }
        if (snapshot.hasError) {
          return InlineNotice(
            message: snapshot.error!,
            backgroundColor: ConciergeColors.danger.withValues(alpha: 0.14),
            foregroundColor: ConciergeColors.danger,
          );
        }
        final viewer = snapshot.data;
        return InlineNotice(
          message: viewer == null
              ? 'Backend: users:viewer does not see a Convex Auth user yet.'
              : 'Backend: users:viewer resolves this session to user '
                    '${viewer.userId.value} (created via '
                    '${viewer.createdVia}).',
        );
      },
    );
  }
}

/// Panel shown when Convex Auth cannot be used with the current deployment.
class ConvexAuthSetupPanel extends StatelessWidget {
  const ConvexAuthSetupPanel({super.key, this.error});

  /// Why the Convex Auth client could not be created, when a deployment URL
  /// is set but the adapter refused it.
  final String? error;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      eyebrow: 'CONVEX AUTH SETUP',
      title: 'Convex Auth Not Configured',
      subtitle:
          'Convex Auth requires a Convex deployment with the '
          '@convex-dev/auth components installed.',
      trailing: const ThreadPill(
        label: 'Setup',
        backgroundColor: Color(0xFF54340E),
        foregroundColor: ConciergeColors.warning,
        icon: Icons.warning_amber_rounded,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (error != null) ...<Widget>[
            InlineNotice(
              message: error!,
              backgroundColor: ConciergeColors.danger.withValues(alpha: 0.14),
              foregroundColor: ConciergeColors.danger,
            ),
            const SizedBox(height: 16),
          ],
          const InlineNotice(
            message: 'Complete the following steps to enable Convex Auth:',
          ),
          const SizedBox(height: 16),
          const _ChecklistItem(
            number: '1',
            title: 'Install the backend',
            detail:
                'cd example/convex-backend\n'
                'npm install   # includes @convex-dev/auth',
          ),
          const SizedBox(height: 8),
          const _ChecklistItem(
            number: '2',
            title: 'Deploy',
            detail:
                'npx convex dev   # or npx convex deploy\n'
                'No secret to set: tokens are signed by the deployment.',
          ),
          const SizedBox(height: 8),
          const _ChecklistItem(
            number: '3',
            title: 'Run the demo',
            detail:
                'flutter run '
                '--dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud',
          ),
        ],
      ),
    );
  }
}

String _formatDateTime(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

class _ChecklistItem extends StatelessWidget {
  const _ChecklistItem({
    required this.number,
    required this.title,
    required this.detail,
  });

  final String number;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: ConciergeColors.surfaceHigh.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: ConciergeColors.outline.withValues(alpha: 0.58),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Container(
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: const Color(0xFF0F3F2A),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              number,
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: ConciergeColors.cyanSoft,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  detail,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: ConciergeColors.textMuted,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
  });

  final String label;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: foregroundColor.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: foregroundColor,
            fontWeight: FontWeight.w800,
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }
}
