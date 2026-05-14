import 'package:flutter/material.dart';

import 'concierge_design.dart';

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.eyebrow,
    this.trailing,
    this.backgroundColor,
    this.borderColor,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final String? eyebrow;
  final Widget? trailing;
  final Color? backgroundColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompactHeader = trailing != null && constraints.maxWidth < 560;
        final cardPadding = constraints.maxWidth < 380 ? 16.0 : 20.0;
        final titleBlock = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (eyebrow != null) ...<Widget>[
              Text(
                eyebrow!,
                softWrap: true,
                style: textTheme.labelMedium?.copyWith(
                  color: ConciergeColors.cyanSoft,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 6),
            ],
            Text(
              title,
              softWrap: true,
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: 0,
              ),
            ),
          ],
        );

        return Container(
          decoration: BoxDecoration(
            color: backgroundColor,
            gradient: backgroundColor == null
                ? const LinearGradient(
                    colors: <Color>[
                      Color(0xFF1C2636),
                      ConciergeColors.surfaceLow,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color:
                  borderColor ?? ConciergeColors.cyan.withValues(alpha: 0.14),
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: ConciergeColors.surfaceLowest.withValues(alpha: 0.48),
                blurRadius: 32,
                offset: const Offset(0, 18),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.all(cardPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (isCompactHeader) ...<Widget>[
                  titleBlock,
                  const SizedBox(height: 12),
                  Align(alignment: Alignment.centerLeft, child: trailing),
                ] else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(child: titleBlock),
                      if (trailing != null) ...<Widget>[
                        const SizedBox(width: 12),
                        Flexible(child: Align(child: trailing)),
                      ],
                    ],
                  ),
                const SizedBox(height: 6),
                Text(
                  subtitle,
                  softWrap: true,
                  style: textTheme.bodyMedium?.copyWith(
                    color: ConciergeColors.textMuted,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 16),
                child,
              ],
            ),
          ),
        );
      },
    );
  }
}
