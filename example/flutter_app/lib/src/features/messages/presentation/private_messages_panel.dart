import 'package:flutter/material.dart';

import '../../../../convex_api/api.dart';
import '../../../../convex_api/modules/messages.dart' as messages_api;
import '../../shared/presentation/conversation_widgets.dart';
import '../../shared/presentation/generated_subscription_builder.dart';
import '../../shared/presentation/section_card.dart';

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
      await api.messages.sendprivate(text: text);
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
          'Same Convex subscription model, but scoped to the authenticated '
          'viewer and guarded by JWT auth.',
      trailing: const ThreadPill(
        label: 'JWT required',
        backgroundColor: Color(0xFF3C2620),
        foregroundColor: Color(0xFFD4845A),
        icon: Icons.lock_outline_rounded,
      ),
      backgroundColor: Color(0xFF1A1F2E).withValues(alpha: 0.92),
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
              subscribe: widget.api!.messages.listprivateSubscribe,
              builder: (context, snapshot) {
                if (snapshot.isLoading) {
                  return const _PrivateThreadSurface(
                    child: Center(
                      child: CircularProgressIndicator(strokeWidth: 2.4),
                    ),
                  );
                }
                if (snapshot.hasError) {
                  final isAuthError = snapshot.error!
                      .toString()
                      .contains('Authentication required');
                  return InlineNotice(
                    message: isAuthError
                        ? 'Authentication required. '
                            'Go to the Auth tab and tap Login to access '
                            'private messages.'
                        : snapshot.error!,
                    backgroundColor: const Color(0xFFFFF1EF),
                    foregroundColor: const Color(0xFF8B4237),
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
                                  'Viewer ${compactToken(item.tokenidentifier)} • '
                                  '${formatMessageTimestamp(item.creationtime)}',
                              alignEnd: true,
                              accentColor: const Color(0xFFD4845A),
                              neutralColor: const Color(0xFF252D3D),
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
              color: const Color(0xFFD4845A).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: const Color(0xFFD4845A).withValues(alpha: 0.25),
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
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Protected by Convex auth context.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFFA0A9B8),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: widget.api == null || _isSending
                          ? null
                          : _send,
                      style: FilledButton.styleFrom(
                        foregroundColor: const Color(0xFFD4845A),
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
                    backgroundColor: Color(0xFF252D3D).withValues(alpha: 0.72),
                    foregroundColor: const Color(0xFFA0A9B8),
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
          colors: <Color>[Color(0xFF3C2620), Color(0xFF1A1F2E)],
        ),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF8D4B3A),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.shield_moon_outlined, color: Colors.white),
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
                    color: const Color(0xFFA0A9B8),
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
          colors: <Color>[Color(0xFF1A1F2E), Color(0xFF252D3D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFF2D3748)),
      ),
      child: child,
    );
  }
}
