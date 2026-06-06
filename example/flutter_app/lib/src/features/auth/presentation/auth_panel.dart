import 'package:dartvex/dartvex.dart';
import 'package:dartvex_flutter/dartvex_flutter.dart';
import 'package:flutter/material.dart';

import '../../../../convex_api/api.dart';
import '../../../../convex_api/modules/demo.dart' as demo_api;
import '../data/demo_auth_provider.dart';
import '../../shared/presentation/conversation_widgets.dart';
import '../../shared/presentation/concierge_design.dart';
import '../../shared/presentation/generated_subscription_builder.dart';
import '../../shared/presentation/section_card.dart';

class AuthPanel extends StatelessWidget {
  const AuthPanel({
    super.key,
    required this.api,
    required this.authClient,
    required this.demoAuthProvider,
    required this.authStatus,
    required this.onLogin,
    required this.onLoginFromCache,
    required this.onLogout,
    required this.onForceReconnect,
  });

  final ConvexAuthClient<DemoUserSession>? authClient;
  final ConvexApi? api;
  final DemoAuthProvider demoAuthProvider;
  final String? authStatus;
  final Future<void> Function() onLogin;
  final Future<void> Function() onLoginFromCache;
  final Future<void> Function() onLogout;
  final Future<void> Function() onForceReconnect;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      eyebrow: 'AUTH FLOW',
      title: 'Demo Auth',
      subtitle:
          'Showcases provider-backed login, cached session restore, and silent '
          'token refresh after reconnect.',
      trailing: const ThreadPill(
        label: 'Auth client',
        backgroundColor: Color(0x1A00D1FF),
        foregroundColor: ConciergeColors.cyanSoft,
        icon: Icons.verified_user_outlined,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const InlineNotice(
            message:
                'Local demo provider. Reconnect drops the socket so silent '
                'refresh becomes visible.',
          ),
          if (!demoAuthProvider.hasConfiguredToken) ...<Widget>[
            const SizedBox(height: 12),
            const _DemoAuthSetupGuide(),
          ],
          if (authStatus != null) ...<Widget>[
            const SizedBox(height: 12),
            InlineNotice(
              message: authStatus!,
              backgroundColor: ConciergeColors.surfaceHigh,
              foregroundColor: ConciergeColors.textMuted,
            ),
          ],
          const SizedBox(height: 18),
          if (authClient == null)
            const InlineNotice(
              message:
                  'Set CONVEX_DEMO_URL to enable the auth demo and live reconnect flow.',
            )
          else ...<Widget>[
            ConvexAuthBuilder<DemoUserSession>(
              builder: (context, state) {
                final stateLabel = switch (state) {
                  AuthLoading<DemoUserSession>() => 'Loading',
                  AuthAuthenticated<DemoUserSession>() => 'Signed in',
                  AuthUnauthenticated<DemoUserSession>() => 'Signed out',
                };
                final isLoading = state is AuthLoading<DemoUserSession>;
                final isAuthenticated =
                    state is AuthAuthenticated<DemoUserSession>;
                final session = switch (state) {
                  AuthAuthenticated<DemoUserSession>(:final userInfo) =>
                    userInfo,
                  _ => null,
                };

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: <Widget>[
                        _StatusPill(
                          label: 'Auth: $stateLabel',
                          backgroundColor: switch (state) {
                            AuthLoading<DemoUserSession>() => const Color(
                              0xFF2C1F5C,
                            ),
                            AuthAuthenticated<DemoUserSession>() => const Color(
                              0xFF0D3D37,
                            ),
                            AuthUnauthenticated<DemoUserSession>() =>
                              const Color(0xFF5F1515),
                          },
                          foregroundColor: switch (state) {
                            AuthLoading<DemoUserSession>() => const Color(
                              0xFF00D1FF,
                            ),
                            AuthAuthenticated<DemoUserSession>() => const Color(
                              0xFF3DFFC2,
                            ),
                            AuthUnauthenticated<DemoUserSession>() =>
                              const Color(0xFFFF8A80),
                          },
                        ),
                        ConvexConnectionBuilder(
                          builder: (context, connectionState) => _StatusPill(
                            label: 'Realtime: ${connectionState.name}',
                            backgroundColor:
                                connectionState ==
                                    ConvexConnectionState.connected
                                ? const Color(0xFF0D3D37)
                                : const Color(0xFF2C1F5C),
                            foregroundColor:
                                connectionState ==
                                    ConvexConnectionState.connected
                                ? ConciergeColors.success
                                : ConciergeColors.cyan,
                          ),
                        ),
                        AnimatedBuilder(
                          animation: demoAuthProvider,
                          builder: (context, _) => _StatusPill(
                            label: demoAuthProvider.hasConfiguredToken
                                ? 'Demo token ready'
                                : 'Demo token missing',
                            backgroundColor: demoAuthProvider.hasConfiguredToken
                                ? const Color(0xFF0D3D37)
                                : const Color(0xFF54340E),
                            foregroundColor: demoAuthProvider.hasConfiguredToken
                                ? ConciergeColors.success
                                : ConciergeColors.warning,
                          ),
                        ),
                        AnimatedBuilder(
                          animation: demoAuthProvider,
                          builder: (context, _) => _StatusPill(
                            label: demoAuthProvider.hasCachedSession
                                ? 'Session cached'
                                : 'No session cache',
                            backgroundColor: demoAuthProvider.hasCachedSession
                                ? const Color(0xFF1F2937)
                                : const Color(0xFF54340E),
                            foregroundColor: demoAuthProvider.hasCachedSession
                                ? ConciergeColors.textMuted
                                : ConciergeColors.warning,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ConvexConnectionBuilder(
                      builder: (context, connectionState) {
                        final canLogin =
                            !isLoading && demoAuthProvider.hasConfiguredToken;
                        final canUseCache =
                            !isLoading && demoAuthProvider.hasCachedSession;
                        final canLogout = !isLoading && isAuthenticated;
                        final canForceReconnect =
                            !isLoading &&
                            demoAuthProvider.hasConfiguredToken &&
                            connectionState == ConvexConnectionState.connected;

                        return Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: <Widget>[
                            FilledButton(
                              onPressed: canLogin ? onLogin : null,
                              child: Text(
                                isLoading ? 'Logging in...' : 'Login',
                              ),
                            ),
                            FilledButton.tonal(
                              onPressed: canUseCache ? onLoginFromCache : null,
                              child: const Text('Restore Session'),
                            ),
                            OutlinedButton(
                              onPressed: canLogout ? onLogout : null,
                              child: const Text('Logout'),
                            ),
                            OutlinedButton(
                              onPressed: canForceReconnect
                                  ? onForceReconnect
                                  : null,
                              child: const Text('Reconnect'),
                            ),
                          ],
                        );
                      },
                    ),
                    if (session != null) ...<Widget>[
                      const SizedBox(height: 16),
                      _SessionSummary(session: session),
                    ],
                  ],
                );
              },
            ),
            const SizedBox(height: 18),
            AnimatedBuilder(
              animation: demoAuthProvider,
              builder: (context, _) =>
                  _ProviderDiagnostics(provider: demoAuthProvider),
            ),
            const SizedBox(height: 18),
            if (api == null)
              const InlineNotice(
                message:
                    'Viewer state will appear once CONVEX_DEMO_URL is set.',
              )
            else
              GeneratedSubscriptionBuilder<demo_api.WhoAmIResult?>(
                subscriptionKey: api!,
                subscribe: api!.demo.whoAmISubscribe,
                builder: (context, snapshot) {
                  if (snapshot.isLoading) {
                    return const LinearProgressIndicator(minHeight: 2);
                  }
                  if (snapshot.hasError) {
                    return InlineNotice(
                      message: snapshot.error!,
                      backgroundColor: ConciergeColors.danger.withValues(
                        alpha: 0.14,
                      ),
                      foregroundColor: ConciergeColors.danger,
                    );
                  }
                  final viewer = snapshot.data;
                  if (viewer == null) {
                    return const InlineNotice(
                      message:
                          'Current viewer is anonymous. Use Login to unlock the private feed and viewer query.',
                    );
                  }
                  return Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: ConciergeColors.cyan.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: ConciergeColors.cyan.withValues(alpha: 0.18),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Current viewer',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: ConciergeColors.cyanSoft,
                                fontWeight: FontWeight.w800,
                              ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          viewer.name ?? viewer.email ?? viewer.subject,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        SelectableText(
                          'tokenIdentifier: ${viewer.tokenIdentifier}',
                        ),
                      ],
                    ),
                  );
                },
              ),
          ],
        ],
      ),
    );
  }
}

class _DemoAuthSetupGuide extends StatelessWidget {
  const _DemoAuthSetupGuide();

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF54340E).withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: ConciergeColors.warning.withValues(alpha: 0.28),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(
                Icons.key_off_rounded,
                color: ConciergeColors.warning,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Demo auth setup required',
                      style: textTheme.titleSmall?.copyWith(
                        color: ConciergeColors.warning,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Login is disabled because no CONVEX_DEMO_AUTH_TOKEN was '
                      'provided. Public tabs and Better Auth do not need this '
                      'token.',
                      style: textTheme.bodySmall?.copyWith(
                        color: ConciergeColors.text,
                        height: 1.35,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          const _SetupStep(
            number: '1',
            title: 'Generate local demo JWT material',
            body:
                'This creates a gitignored .env file containing the private '
                'key and prints the public JWKS command.',
            command: 'cd example/convex-backend && npm run demo:key',
          ),
          const SizedBox(height: 12),
          const _SetupStep(
            number: '2',
            title: 'Configure Convex with the public JWKS',
            body:
                'Run the printed npx convex env set DEMO_JWKS ... command. '
                'Only the public JWKS goes to Convex; the private key stays '
                'local.',
          ),
          const SizedBox(height: 12),
          const _SetupStep(
            number: '3',
            title: 'Launch Flutter with a generated JWT',
            body:
                'After restart, the Demo Login button enables and signs the '
                'demo viewer with ConvexClientWithAuth.',
            command:
                'flutter run --dart-define=CONVEX_DEMO_URL=https://your-deployment.convex.cloud '
                r'--dart-define=CONVEX_DEMO_AUTH_TOKEN="$(cd ../convex-backend && npm run -s token)"',
          ),
          const SizedBox(height: 12),
          Text(
            'No default private key or bundled JWT is shipped with this repo.',
            style: textTheme.bodySmall?.copyWith(
              color: ConciergeColors.warning,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupStep extends StatelessWidget {
  const _SetupStep({
    required this.number,
    required this.title,
    required this.body,
    this.command,
  });

  final String number;
  final String title;
  final String body;
  final String? command;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: ConciergeColors.warning.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: ConciergeColors.warning.withValues(alpha: 0.28),
            ),
          ),
          child: Text(
            number,
            style: textTheme.labelSmall?.copyWith(
              color: ConciergeColors.warning,
              fontWeight: FontWeight.w900,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: textTheme.bodyMedium?.copyWith(
                  color: ConciergeColors.text,
                  fontWeight: FontWeight.w800,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                body,
                style: textTheme.bodySmall?.copyWith(
                  color: ConciergeColors.textMuted,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (command != null) ...<Widget>[
                const SizedBox(height: 8),
                _CommandLine(command!),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _CommandLine extends StatelessWidget {
  const _CommandLine(this.command);

  final String command;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: ConciergeColors.surfaceLowest.withValues(alpha: 0.52),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: ConciergeColors.warning.withValues(alpha: 0.16),
        ),
      ),
      child: SelectableText(
        command,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: ConciergeColors.cyanSoft,
          fontFamily: 'monospace',
          height: 1.35,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ProviderDiagnostics extends StatelessWidget {
  const _ProviderDiagnostics({required this.provider});

  final DemoAuthProvider provider;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ConciergeColors.surfaceHigh.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: ConciergeColors.outline.withValues(alpha: 0.58),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Provider diagnostics',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: <Widget>[
              _MetricTile(
                label: 'login()',
                value: provider.loginCalls.toString(),
              ),
              _MetricTile(
                label: 'loginFromCache()',
                value: provider.loginFromCacheCalls.toString(),
              ),
              _MetricTile(
                label: 'logout()',
                value: provider.logoutCalls.toString(),
              ),
            ],
          ),
          if (provider.cachedSession != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              'Cached session: ${provider.cachedSession!.displayName} '
              '(${provider.cachedSession!.tokenLabel})',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: ConciergeColors.textMuted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'Recent events',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          for (final event in provider.eventLog)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                event,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: ConciergeColors.textMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 120),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: ConciergeColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: ConciergeColors.outline.withValues(alpha: 0.58),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: ConciergeColors.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionSummary extends StatelessWidget {
  const _SessionSummary({required this.session});

  final DemoUserSession session;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: ConciergeColors.cyan.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ConciergeColors.cyan.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Authenticated session',
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: ConciergeColors.cyanSoft,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            session.displayName,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 6),
          Text('userId: ${session.userId}'),
          Text('token source: ${session.tokenLabel}'),
          Text('cache refresh count: ${session.cacheRestoreCount}'),
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
