import 'package:flutter/material.dart';

/// The "concierge" dark palette shared with the Dartvex end-to-end demo app:
/// a deep navy canvas with a cyan accent and mint/amber/coral semantics.
abstract final class ConciergeColors {
  /// Page canvas behind the gradient background.
  static const Color background = Color(0xFF0C1321);

  /// Darkest surface, used for inset wells and the gradient's bottom stop.
  static const Color surfaceLowest = Color(0xFF070E1C);

  /// Low-emphasis surface (app bar, subtle wells).
  static const Color surfaceLow = Color(0xFF151B2A);

  /// Default card/container surface.
  static const Color surface = Color(0xFF19202E);

  /// Raised surface for chips and the navigation bar.
  static const Color surfaceHigh = Color(0xFF232A39);

  /// Highest surface, used for the most prominent raised elements.
  static const Color surfaceHighest = Color(0xFF2E3544);

  /// Hairline outline color.
  static const Color outline = Color(0xFF3C494E);

  /// Stronger outline for higher-contrast borders.
  static const Color outlineStrong = Color(0xFF859399);

  /// Primary body text color.
  static const Color text = Color(0xFFDCE2F6);

  /// Muted text for secondary content.
  static const Color textMuted = Color(0xFFBBC9CF);

  /// Dim text for labels and captions.
  static const Color textDim = Color(0xFF7C8A9A);

  /// The cyan brand accent.
  static const Color cyan = Color(0xFF00D1FF);

  /// A softer cyan for text on dark surfaces.
  static const Color cyanSoft = Color(0xFFA4E6FF);

  /// Secondary blue accent.
  static const Color blue = Color(0xFF0056FD);

  /// Secondary lavender accent.
  static const Color secondary = Color(0xFFB6C4FF);

  /// Positive/connected semantic color (mint).
  static const Color success = Color(0xFF3DFFC2);

  /// Warning/refreshing semantic color (amber).
  static const Color warning = Color(0xFFFFC46B);

  /// Error/disconnected semantic color (coral).
  static const Color danger = Color(0xFFFF8A80);
}

/// Builds the dark, cyan-accented [ThemeData] used by this example, mirroring
/// the Dartvex demo app's "concierge" charte.
ThemeData buildConciergeTheme() {
  final colorScheme =
      ColorScheme.fromSeed(
        seedColor: ConciergeColors.cyan,
        brightness: Brightness.dark,
      ).copyWith(
        primary: ConciergeColors.cyan,
        onPrimary: ConciergeColors.surfaceLowest,
        secondary: ConciergeColors.secondary,
        surface: ConciergeColors.surface,
        onSurface: ConciergeColors.text,
        surfaceContainerLowest: ConciergeColors.surfaceLowest,
        surfaceContainerLow: ConciergeColors.surfaceLow,
        surfaceContainer: ConciergeColors.surface,
        surfaceContainerHigh: ConciergeColors.surfaceHigh,
        surfaceContainerHighest: ConciergeColors.surfaceHighest,
        outline: ConciergeColors.outlineStrong,
        outlineVariant: ConciergeColors.outline,
        error: ConciergeColors.danger,
      );

  final base = ThemeData(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: ConciergeColors.background,
    useMaterial3: true,
    fontFamily: 'Hanken Grotesk',
  );
  final textTheme = base.textTheme.apply(
    bodyColor: ConciergeColors.text,
    displayColor: ConciergeColors.text,
  );

  return base.copyWith(
    textTheme: textTheme,
    appBarTheme: const AppBarTheme(
      backgroundColor: ConciergeColors.surfaceLow,
      foregroundColor: ConciergeColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: ConciergeColors.surface,
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: ConciergeColors.cyan.withValues(alpha: 0.14)),
      ),
    ),
    dividerTheme: DividerThemeData(
      space: 1,
      thickness: 1,
      color: ConciergeColors.outline.withValues(alpha: 0.35),
    ),
    listTileTheme: const ListTileThemeData(
      iconColor: ConciergeColors.textMuted,
      textColor: ConciergeColors.text,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith<Color?>(
        (states) => states.contains(WidgetState.selected)
            ? ConciergeColors.surfaceLowest
            : ConciergeColors.textDim,
      ),
      trackColor: WidgetStateProperty.resolveWith<Color?>(
        (states) => states.contains(WidgetState.selected)
            ? ConciergeColors.cyan
            : ConciergeColors.surfaceHigh,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: ConciergeColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      labelStyle: const TextStyle(color: ConciergeColors.textMuted),
      hintStyle: TextStyle(
        color: ConciergeColors.textDim.withValues(alpha: 0.8),
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: ConciergeColors.outline.withValues(alpha: 0.58),
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(
          color: ConciergeColors.outline.withValues(alpha: 0.58),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: ConciergeColors.cyan, width: 1.4),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: ConciergeColors.surfaceHigh,
      selectedColor: ConciergeColors.cyan.withValues(alpha: 0.16),
      side: BorderSide(color: ConciergeColors.outline.withValues(alpha: 0.55)),
      labelStyle: const TextStyle(color: ConciergeColors.text),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: ConciergeColors.cyan,
        foregroundColor: ConciergeColors.surfaceLowest,
        disabledBackgroundColor: ConciergeColors.surfaceHigh,
        disabledForegroundColor: ConciergeColors.textDim,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        foregroundColor: ConciergeColors.cyanSoft,
        side: BorderSide(color: ConciergeColors.cyan.withValues(alpha: 0.52)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: ConciergeColors.cyanSoft,
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: ConciergeColors.cyan,
      foregroundColor: ConciergeColors.surfaceLowest,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: ConciergeColors.cyan,
      linearTrackColor: ConciergeColors.surfaceHigh,
      circularTrackColor: ConciergeColors.surfaceHigh,
    ),
  );
}

/// A vertical navy gradient backdrop, matching the demo app's canvas.
class ConciergeBackground extends StatelessWidget {
  /// Creates a [ConciergeBackground] wrapping [child].
  const ConciergeBackground({super.key, required this.child});

  /// The content painted on top of the gradient.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[
            ConciergeColors.background,
            ConciergeColors.surfaceLowest,
          ],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: child,
    );
  }
}

/// A circular, cyan-bordered brand mark echoing the demo app's logo treatment.
///
/// This example keeps itself dependency-free, so it draws a glyph rather than
/// the SVG wordmark used by the full demo app.
class DartvexLogoMark extends StatelessWidget {
  /// Creates a [DartvexLogoMark] of the given [size], with an optional [glow].
  const DartvexLogoMark({super.key, this.size = 36, this.glow = true});

  /// The diameter of the circular mark.
  final double size;

  /// Whether to render a soft cyan glow around the mark.
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: ConciergeColors.surfaceLowest,
        shape: BoxShape.circle,
        border: Border.all(color: ConciergeColors.cyan.withValues(alpha: 0.5)),
        boxShadow: glow
            ? <BoxShadow>[
                BoxShadow(
                  color: ConciergeColors.cyan.withValues(alpha: 0.22),
                  blurRadius: 24,
                  spreadRadius: 1,
                ),
              ]
            : null,
      ),
      child: Icon(
        Icons.bolt_rounded,
        size: size * 0.58,
        color: ConciergeColors.cyan,
      ),
    );
  }
}
