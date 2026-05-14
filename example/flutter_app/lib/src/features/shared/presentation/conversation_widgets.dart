import 'package:flutter/material.dart';

import 'concierge_design.dart';

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
        border: Border.all(color: foregroundColor.withValues(alpha: 0.22)),
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
                letterSpacing: 0,
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
    this.accentColor = ConciergeColors.cyan,
    this.neutralColor = ConciergeColors.surfaceHigh,
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
    const foreground = ConciergeColors.text;
    return Align(
      alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          decoration: BoxDecoration(
            color: alignEnd ? null : bubbleColor,
            gradient: alignEnd
                ? LinearGradient(
                    colors: <Color>[
                      ConciergeColors.surfaceHigh,
                      accentColor.withValues(alpha: 0.36),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(18),
              topRight: const Radius.circular(18),
              bottomLeft: Radius.circular(alignEnd ? 18 : 4),
              bottomRight: Radius.circular(alignEnd ? 4 : 18),
            ),
            border: Border.all(
              color: alignEnd
                  ? accentColor.withValues(alpha: 0.34)
                  : ConciergeColors.outline.withValues(alpha: 0.58),
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: (alignEnd ? accentColor : Colors.black).withValues(
                  alpha: alignEnd ? 0.10 : 0.24,
                ),
                blurRadius: 18,
                offset: const Offset(0, 10),
              ),
            ],
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
                    fontWeight: FontWeight.w800,
                    fontSize: 13,
                    letterSpacing: 0,
                  ),
                ),
                const SizedBox(height: 5),
                Text(body, style: TextStyle(color: foreground, height: 1.36)),
                const SizedBox(height: 8),
                Text(
                  meta,
                  style: TextStyle(
                    color: foreground.withValues(alpha: 0.62),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0,
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
            Icon(icon, size: 24, color: ConciergeColors.textDim),
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
                color: ConciergeColors.textMuted,
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
    this.backgroundColor = ConciergeColors.surfaceHigh,
    this.foregroundColor = ConciergeColors.textMuted,
  });

  final String message;
  final Color backgroundColor;
  final Color foregroundColor;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: foregroundColor.withValues(alpha: 0.14)),
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

class ResponsiveActionFooter extends StatelessWidget {
  const ResponsiveActionFooter({
    super.key,
    required this.message,
    required this.actions,
  });

  final String message;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final messageText = Text(
      message,
      softWrap: true,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(
        color: ConciergeColors.textMuted,
        fontWeight: FontWeight.w600,
        height: 1.35,
      ),
    );
    final actionWrap = Wrap(
      spacing: 8,
      runSpacing: 8,
      alignment: WrapAlignment.end,
      children: actions,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 560) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              messageText,
              const SizedBox(height: 12),
              Align(alignment: Alignment.centerLeft, child: actionWrap),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(child: messageText),
            const SizedBox(width: 12),
            Flexible(
              child: Align(alignment: Alignment.centerRight, child: actionWrap),
            ),
          ],
        );
      },
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
