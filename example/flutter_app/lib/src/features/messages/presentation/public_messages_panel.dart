import 'package:flutter/material.dart';

import '../../../../convex_api/api.dart';
import '../../../../convex_api/modules/messages.dart' as messages_api;
import '../../shared/presentation/conversation_widgets.dart';
import '../../shared/presentation/generated_subscription_builder.dart';
import '../../shared/presentation/section_card.dart';

class PublicMessagesPanel extends StatefulWidget {
  const PublicMessagesPanel({super.key, required this.api});

  final ConvexApi? api;

  @override
  State<PublicMessagesPanel> createState() => _PublicMessagesPanelState();
}

class _PublicMessagesPanelState extends State<PublicMessagesPanel> {
  late final TextEditingController _authorController;
  late final TextEditingController _messageController;
  bool _isSending = false;
  bool _isClearing = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _authorController = TextEditingController(text: 'Anonymous Friend');
    _messageController = TextEditingController();
  }

  @override
  void dispose() {
    _authorController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final api = widget.api;
    if (api == null) {
      return;
    }
    final author = _authorController.text.trim();
    final text = _messageController.text.trim();
    if (author.isEmpty || text.isEmpty) {
      setState(() {
        _status = 'Both author and text are required.';
      });
      return;
    }

    setState(() {
      _isSending = true;
      _status = null;
    });

    try {
      await api.messages.sendpublic(author: author, text: text);
      _messageController.clear();
      setState(() {
        _status = 'Message sent to the public room.';
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

  Future<void> _clearAll() async {
    final api = widget.api;
    if (api == null) return;

    setState(() {
      _isClearing = true;
      _status = null;
    });
    try {
      final count = await api.messages.clearpublic();
      setState(() {
        _status = '${count.toInt()} message${count.toInt() == 1 ? '' : 's'} cleared.';
      });
    } catch (error) {
      setState(() {
        _status = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isClearing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentAuthor = _authorController.text.trim();
    return SectionCard(
      eyebrow: 'PUBLIC ROOM',
      title: 'Public Realtime Feed',
      subtitle:
          'Open lobby backed by a Convex live query. Any visitor can join, '
          'post, and instantly see updates.',
      trailing: const ThreadPill(
        label: 'No auth',
        backgroundColor: Color(0xFF0D3D37),
        foregroundColor: Color(0xFF10B981),
        icon: Icons.public,
      ),
      backgroundColor: Color(0xFF1A1F2E).withValues(alpha: 0.92),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _RoomHeader(
            title: '# public-lobby',
            description:
                'Baseline Convex flow: query + mutation without login.',
            accentColor: const Color(0xFF10B981),
          ),
          const SizedBox(height: 16),
          if (widget.api == null)
            const InlineNotice(
              message: 'Set CONVEX_DEMO_URL to load the live public thread.',
            )
          else
            GeneratedSubscriptionBuilder<
              List<messages_api.ListPublicResultItem>
            >(
              subscriptionKey: widget.api!,
              subscribe: widget.api!.messages.listpublicSubscribe,
              builder: (context, snapshot) {
                if (snapshot.isLoading) {
                  return const _ThreadLoading();
                }
                if (snapshot.hasError) {
                  return InlineNotice(
                    message: snapshot.error!,
                    backgroundColor: const Color(0xFFFFF1EF),
                    foregroundColor: const Color(0xFF8B4237),
                  );
                }
                final items =
                    snapshot.data ??
                    const <messages_api.ListPublicResultItem>[];
                return _ThreadSurface(
                  child: items.isEmpty
                      ? const EmptyThreadState(
                          title: 'No public messages yet',
                          body:
                              'Send the first message to prove the anonymous '
                              'Convex flow is live.',
                          icon: Icons.mark_chat_unread_outlined,
                        )
                      : ListView.separated(
                          itemCount: items.length,
                          reverse: false,
                          separatorBuilder: (context, index) =>
                              const SizedBox(height: 12),
                          itemBuilder: (context, index) {
                            final item = items[index];
                            final isOwnMessage =
                                currentAuthor.isNotEmpty &&
                                item.author == currentAuthor;
                            return ChatBubble(
                              title: item.author,
                              body: item.text,
                              meta:
                                  'Live at ${formatMessageTimestamp(item.creationtime)}',
                              alignEnd: isOwnMessage,
                              accentColor: const Color(0xFF10B981),
                              neutralColor: const Color(0xFF252D3D),
                            );
                          },
                        ),
                );
              },
            ),
          const SizedBox(height: 18),
          _ComposerCard(
            accentColor: const Color(0xFF10B981),
            title: 'Send to #public-lobby',
            status: _status,
            child: Column(
              children: <Widget>[
                TextField(
                  controller: _authorController,
                  decoration: const InputDecoration(
                    labelText: 'Display name',
                    hintText: 'Anonymous Friend',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _messageController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Message',
                    hintText: 'Say something to the public room',
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        'Anonymous and realtime.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFFA0A9B8),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: widget.api == null || _isClearing ? null : _clearAll,
                      icon: Icon(_isClearing ? Icons.hourglass_top : Icons.delete_sweep_rounded),
                      label: Text(_isClearing ? 'Clearing...' : 'Clear all'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: widget.api == null || _isSending
                          ? null
                          : _send,
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF10B981),
                      ),
                      icon: Icon(
                        _isSending ? Icons.hourglass_top : Icons.send_rounded,
                      ),
                      label: Text(_isSending ? 'Sending...' : 'Send'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class MessageTile extends StatelessWidget {
  const MessageTile({
    super.key,
    required this.title,
    required this.body,
    required this.footer,
    this.alignEnd = false,
  });

  final String title;
  final String body;
  final String footer;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    return ChatBubble(
      title: title,
      body: body,
      meta: footer,
      alignEnd: alignEnd,
    );
  }
}

class _RoomHeader extends StatelessWidget {
  const _RoomHeader({
    required this.title,
    required this.description,
    required this.accentColor,
  });

  final String title;
  final String description;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: accentColor,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(Icons.forum_rounded, color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
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

class _ThreadSurface extends StatelessWidget {
  const _ThreadSurface({required this.child});

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

class _ComposerCard extends StatelessWidget {
  const _ComposerCard({
    required this.accentColor,
    required this.title,
    required this.child,
    this.status,
  });

  final Color accentColor;
  final String title;
  final Widget child;
  final String? status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: accentColor.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 14),
          child,
          if (status != null) ...<Widget>[
            const SizedBox(height: 12),
            InlineNotice(
              message: status!,
              backgroundColor: Colors.white.withValues(alpha: 0.7),
              foregroundColor: const Color(0xFF47635F),
            ),
          ],
        ],
      ),
    );
  }
}

class _ThreadLoading extends StatelessWidget {
  const _ThreadLoading();

  @override
  Widget build(BuildContext context) {
    return const _ThreadSurface(
      child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
    );
  }
}
