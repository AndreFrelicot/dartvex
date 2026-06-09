import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../../convex_api/api.dart';
import '../../../../convex_api/modules/messages.dart' as messages_api;
import '../../shared/presentation/conversation_widgets.dart';
import '../../shared/presentation/concierge_design.dart';
import '../../shared/presentation/generated_subscription_builder.dart';
import '../../shared/presentation/section_card.dart';

/// Display label for the authenticated user in the private thread, suffixed
/// with the running platform (e.g. "Authenticated User - iOS") so the demo
/// shows where each message originated. Passed as the optional `author` arg to
/// `messages:sendPrivate`; the message is still gated on a verified identity.
String _authenticatedUserLabel() {
  final platform = kIsWeb
      ? 'Web'
      : switch (defaultTargetPlatform) {
          TargetPlatform.iOS => 'iOS',
          TargetPlatform.android => 'Android',
          TargetPlatform.macOS => 'macOS',
          TargetPlatform.windows => 'Windows',
          TargetPlatform.linux => 'Linux',
          TargetPlatform.fuchsia => 'Fuchsia',
        };
  return 'Authenticated User - $platform';
}

class PrivateMessagesPanel extends StatefulWidget {
  const PrivateMessagesPanel({super.key, required this.api});

  final ConvexApi? api;

  @override
  State<PrivateMessagesPanel> createState() => _PrivateMessagesPanelState();
}

class _PrivateMessagesPanelState extends State<PrivateMessagesPanel> {
  late final TextEditingController _messageController;
  bool _isSending = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _messageController = TextEditingController();
  }

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final api = widget.api;
    if (api == null) {
      return;
    }
    final text = _messageController.text.trim();
    if (text.isEmpty) {
      setState(() {
        _status = 'Message text is required.';
      });
      return;
    }

    setState(() {
      _isSending = true;
      _status = null;
    });

    try {
      await api.messages.sendPrivate(
        text: text,
        author: Optional.of(_authenticatedUserLabel()),
      );
      _messageController.clear();
      setState(() {
        _status = 'Private message delivered.';
      });
    } catch (error) {
      setState(() {
        _status = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      eyebrow: 'PRIVATE THREAD',
      title: 'Secure Realtime Feed',
      subtitle:
          'Same Convex subscription model, scoped to the viewer authenticated '
          'by the active Auth mode shown in the connection chip.',
      trailing: const ThreadPill(
        label: 'Auth required',
        backgroundColor: Color(0x1AB6C4FF),
        foregroundColor: ConciergeColors.secondary,
        icon: Icons.lock_outline_rounded,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const _PrivateHeader(),
          const SizedBox(height: 16),
          if (widget.api == null)
            const InlineNotice(
              message:
                  'Set CONVEX_DEMO_URL to connect the authenticated private thread.',
            )
          else
            GeneratedSubscriptionBuilder<
              List<messages_api.ListPrivateResultItem>
            >(
              subscriptionKey: widget.api!,
              subscribe: widget.api!.messages.listPrivateSubscribe,
              builder: (context, snapshot) {
                if (snapshot.isLoading) {
                  return const _PrivateThreadSurface(
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  );
                }
                if (snapshot.hasError) {
                  final isAuthError = snapshot.error!.toString().contains(
                    'Authentication required',
                  );
                  return InlineNotice(
                    message: isAuthError
                        ? 'Authentication required. '
                              'Go to the Auth tab and tap Login to access '
                              'private messages.'
                        : snapshot.error!,
                    backgroundColor: ConciergeColors.danger.withValues(
                      alpha: 0.14,
                    ),
                    foregroundColor: ConciergeColors.danger,
                  );
                }
                final items =
                    snapshot.data ??
                    const <messages_api.ListPrivateResultItem>[];
                return _PrivateThreadSurface(
                  child: items.isEmpty
                      ? const EmptyThreadState(
                          title: 'Private thread is empty',
                          body:
                              'Apply a token, then send a message to watch the '
                              'authenticated stream update in place.',
                          icon: Icons.lock_person_outlined,
                        )
                      : ListView.separated(
                          itemCount: items.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final item = items[index];
                            return ChatBubble(
                              title: item.author,
                              body: item.text,
                              meta:
                                  'Viewer ${compactToken(item.tokenIdentifier)} • '
                                  '${formatMessageTimestamp(item.creationTime)}',
                              alignEnd: true,
                              accentColor: ConciergeColors.secondary,
                              neutralColor: ConciergeColors.surfaceHigh,
                            );
                          },
                        ),
                );
              },
            ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: ConciergeColors.surfaceHigh.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: ConciergeColors.secondary.withValues(alpha: 0.26),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'Send to your private inbox',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _messageController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Private message',
                    hintText: 'Only visible to the authenticated identity',
                  ),
                ),
                const SizedBox(height: 14),
                ResponsiveActionFooter(
                  message:
                      'Protected by the current Convex auth context from the Auth tab.',
                  actions: <Widget>[
                    FilledButton.icon(
                      onPressed: widget.api == null || _isSending
                          ? null
                          : _send,
                      style: FilledButton.styleFrom(
                        backgroundColor: ConciergeColors.cyan,
                        foregroundColor: ConciergeColors.surfaceLowest,
                        disabledBackgroundColor: ConciergeColors.surface,
                        disabledForegroundColor: ConciergeColors.textMuted,
                      ),
                      icon: Icon(
                        _isSending ? Icons.hourglass_top : Icons.lock_open,
                      ),
                      label: Text(_isSending ? 'Sending...' : 'Send Securely'),
                    ),
                  ],
                ),
                if (_status != null) ...<Widget>[
                  const SizedBox(height: 12),
                  InlineNotice(
                    message: _status!,
                    backgroundColor: ConciergeColors.surfaceHigh.withValues(
                      alpha: 0.72,
                    ),
                    foregroundColor: ConciergeColors.textMuted,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PrivateHeader extends StatelessWidget {
  const _PrivateHeader();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: <Color>[ConciergeColors.surfaceHigh, ConciergeColors.surface],
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: ConciergeColors.secondary.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(
              Icons.shield_moon_outlined,
              color: ConciergeColors.secondary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Direct messages',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'If auth is missing, the query returns an error instead of data.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: ConciergeColors.textMuted,
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

class _PrivateThreadSurface extends StatelessWidget {
  const _PrivateThreadSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 340,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: <Color>[
            ConciergeColors.surfaceLow,
            ConciergeColors.surfaceHigh,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: ConciergeColors.secondary.withValues(alpha: 0.14),
        ),
      ),
      child: child,
    );
  }
}
