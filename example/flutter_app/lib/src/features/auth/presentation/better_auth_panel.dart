import 'package:dartvex_auth_better/dartvex_auth_better.dart';
import 'package:dartvex/dartvex.dart';
import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/material.dart';

import '../../shared/presentation/conversation_widgets.dart';
import '../../shared/presentation/section_card.dart';

/// Auth panel shown when Better Auth mode is active.
class BetterAuthPanel extends StatefulWidget {
  const BetterAuthPanel({
    super.key,
    required this.provider,
    required this.authClient,
  });

  final ConvexBetterAuthProvider provider;
  final ConvexClientWithAuth<BetterAuthSession>? authClient;

  @override
  State<BetterAuthPanel> createState() => _BetterAuthPanelState();
}

class _BetterAuthPanelState extends State<BetterAuthPanel>
    with AutomaticKeepAliveClientMixin {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isSignUp = true;
  bool _isLoading = false;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final authClient = widget.authClient;
    if (authClient == null) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      widget.provider.email = _emailController.text.trim();
      widget.provider.password = _passwordController.text;
      if (_isSignUp) {
        // Register via HTTP, then authenticate the Convex WebSocket.
        await widget.provider.client.signUp(
          name: _nameController.text.trim(),
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );
      }
      await authClient.login();
      if (mounted) {
        _nameController.clear();
        _emailController.clear();
        _passwordController.clear();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _logout() async {
    final authClient = widget.authClient;
    if (authClient == null) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      await authClient.logout();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SectionCard(
      eyebrow: 'BETTER AUTH',
      title: 'Better Auth Demo',
      subtitle:
          'Self-hosted authentication running inside your Convex backend. '
          'No external auth service needed — just HTTP calls.',
      trailing: const ThreadPill(
        label: 'Self-hosted',
        backgroundColor: Color(0xFF0D3D37),
        foregroundColor: Color(0xFF10B981),
        icon: Icons.lock_outlined,
      ),
      child: ConvexAuthBuilder<BetterAuthSession>(
        builder: (context, state) {
          return switch (state) {
            AuthAuthenticated<BetterAuthSession>(:final userInfo) =>
              _SignedInContent(
                session: userInfo,
                isLoading: _isLoading,
                error: _error,
                onLogout: _logout,
              ),
            _ => _AuthForm(
                nameController: _nameController,
                emailController: _emailController,
                passwordController: _passwordController,
                isSignUp: _isSignUp,
                isLoading: _isLoading,
                error: _error,
                onToggleMode: () => setState(() => _isSignUp = !_isSignUp),
                onSubmit: _submit,
              ),
          };
        },
      ),
    );
  }
}

class _AuthForm extends StatelessWidget {
  const _AuthForm({
    required this.nameController,
    required this.emailController,
    required this.passwordController,
    required this.isSignUp,
    required this.isLoading,
    required this.error,
    required this.onToggleMode,
    required this.onSubmit,
  });

  final TextEditingController nameController;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final bool isSignUp;
  final bool isLoading;
  final String? error;
  final VoidCallback onToggleMode;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InlineNotice(
          message: isSignUp
              ? 'Create an account with email and password. '
                'Your credentials are stored in the Convex database.'
              : 'Sign in with your existing email and password.',
        ),
        const SizedBox(height: 16),
        if (isSignUp) ...<Widget>[
          TextField(
            controller: nameController,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'John Doe',
            ),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: emailController,
          decoration: const InputDecoration(
            labelText: 'Email',
            hintText: 'user@example.com',
          ),
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: passwordController,
          decoration: const InputDecoration(
            labelText: 'Password',
            hintText: 'min 8 characters',
          ),
          obscureText: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => onSubmit(),
        ),
        if (error != null) ...<Widget>[
          const SizedBox(height: 12),
          InlineNotice(
            message: error!,
            backgroundColor: const Color(0xFF5F1515),
            foregroundColor: const Color(0xFFEF4444),
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
            TextButton(
              onPressed: onToggleMode,
              child: Text(isSignUp
                  ? 'Already have an account? Sign in'
                  : 'Need an account? Sign up'),
            ),
          ],
        ),
      ],
    );
  }
}

class _SignedInContent extends StatelessWidget {
  const _SignedInContent({
    required this.session,
    required this.isLoading,
    required this.error,
    required this.onLogout,
  });

  final BetterAuthSession session;
  final bool isLoading;
  final String? error;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: <Widget>[
            const _StatusPill(
              label: 'Authenticated',
              backgroundColor: Color(0xFF0D3D37),
              foregroundColor: Color(0xFF10B981),
            ),
            ConvexConnectionBuilder(
              builder: (context, connectionState) => _StatusPill(
                label: 'Connection: ${connectionState.name}',
                backgroundColor:
                    connectionState == ConvexConnectionState.connected
                        ? const Color(0xFF0D3D37)
                        : const Color(0xFF2C1F5C),
                foregroundColor:
                    connectionState == ConvexConnectionState.connected
                        ? const Color(0xFF10B981)
                        : const Color(0xFF818CF8),
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Better Auth Session',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: const Color(0xFF10B981),
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                session.name ?? session.email,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text('email: ${session.email}'),
              Text('userId: ${session.userId}'),
            ],
          ),
        ),
        if (error != null) ...<Widget>[
          const SizedBox(height: 12),
          InlineNotice(
            message: error!,
            backgroundColor: const Color(0xFF5F1515),
            foregroundColor: const Color(0xFFEF4444),
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

/// Panel shown when Better Auth is not configured (no deployment URL).
class BetterAuthSetupPanel extends StatelessWidget {
  const BetterAuthSetupPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      eyebrow: 'BETTER AUTH SETUP',
      title: 'Better Auth Not Configured',
      subtitle:
          'Better Auth requires a Convex deployment with the '
          '@convex-dev/better-auth component installed.',
      trailing: const ThreadPill(
        label: 'Setup',
        backgroundColor: Color(0xFF54340E),
        foregroundColor: Color(0xFFF59E0B),
        icon: Icons.warning_amber_rounded,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const InlineNotice(
            message: 'Complete the following steps to enable Better Auth:',
          ),
          const SizedBox(height: 16),
          _ChecklistItem(
            number: '1',
            title: 'Install the component',
            detail:
                'cd demo/convex-backend\n'
                'npm install better-auth@1.5.3 @convex-dev/better-auth',
          ),
          const SizedBox(height: 8),
          _ChecklistItem(
            number: '2',
            title: 'Set the secret',
            detail:
                'npx convex env set BETTER_AUTH_SECRET=\$(openssl rand -base64 32)',
          ),
          const SizedBox(height: 8),
          _ChecklistItem(
            number: '3',
            title: 'Deploy',
            detail: 'npx convex dev   # or npx convex deploy',
          ),
          const SizedBox(height: 8),
          _ChecklistItem(
            number: '4',
            title: 'Run the demo',
            detail:
                'flutter run '
                '--dart-define=CONVEX_DEMO_URL=https://your.convex.cloud',
          ),
        ],
      ),
    );
  }
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
        color: const Color(0xFF252D3D),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2D3748)),
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
                    color: const Color(0xFF10B981),
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
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                SelectableText(
                  detail,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFFA0A9B8),
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
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: foregroundColor,
                fontWeight: FontWeight.w800,
              ),
        ),
      ),
    );
  }
}
