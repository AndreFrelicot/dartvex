import 'package:flutter/material.dart';

class ThreadPill extends StatelessWidget {
  const ThreadPill({
    super.key,
    required this.label,
    required this.backgroundColor,
    required this.foregroundColor,
    this.icon,
  });

  final String label;
  final Color backgroundColor;
  final Color foregroundColor;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              Icon(icon, size: 14, color: foregroundColor),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                color: foregroundColor,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ChatBubble extends StatelessWidget {
  const ChatBubble({
    super.key,
    required this.title,
    required this.body,
    required this.meta,
    this.alignEnd = false,
    this.accentColor = const Color(0xFF4F46E5),
    this.neutralColor = const Color(0xFF252D3D),
  });

  final String title;
  final String body;
  final String meta;
  final bool alignEnd;
  final Color accentColor;
  final Color neutralColor;

  @override
  Widget build(BuildContext context) {
    final bubbleColor = alignEnd ? accentColor : neutralColor;
    final foreground = alignEnd ? Colors.white : const Color(0xFFF3F4F6);
    return Align(
      alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: bubbleColor,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: alignEnd
                  ? accentColor.withValues(alpha: 0.25)
                  : const Color(0xFF2D3748),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    color: foreground,
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                Text(body, style: TextStyle(color: foreground, height: 1.32)),
                const SizedBox(height: 8),
                Text(
                  meta,
                  style: TextStyle(
                    color: foreground.withValues(alpha: alignEnd ? 0.76 : 0.62),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class EmptyThreadState extends StatelessWidget {
  const EmptyThreadState({
    super.key,
    required this.title,
    required this.body,
    this.icon = Icons.forum_outlined,
  });

  final String title;
  final String body;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 24, color: const Color(0xFF6B7280)),
            const SizedBox(height: 10),
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              body,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: const Color(0xFFA0A9B8),
                height: 1.35,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class InlineNotice extends StatelessWidget {
  const InlineNotice({
    super.key,
    required this.message,
    this.backgroundColor = const Color(0xFF1F2937),
    this.foregroundColor = const Color(0xFFA0A9B8),
  });

  final String message;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Text(
          message,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: foregroundColor,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

String formatMessageTimestamp(double creationTime) {
  final createdAt = DateTime.fromMillisecondsSinceEpoch(
    creationTime.toInt(),
  ).toLocal();
  final hours = createdAt.hour.toString().padLeft(2, '0');
  final minutes = createdAt.minute.toString().padLeft(2, '0');
  return '${createdAt.day}/${createdAt.month} $hours:$minutes';
}

String compactToken(String tokenIdentifier) {
  if (tokenIdentifier.length <= 18) {
    return tokenIdentifier;
  }
  return '${tokenIdentifier.substring(0, 10)}...'
      '${tokenIdentifier.substring(tokenIdentifier.length - 6)}';
}
