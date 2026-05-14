import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

const String dartvexLogoAsset = 'assets/dartvex-logo.svg';

abstract final class ConciergeColors {
  static const Color background = Color(0xFF0C1321);
  static const Color surfaceLowest = Color(0xFF070E1C);
  static const Color surfaceLow = Color(0xFF151B2A);
  static const Color surface = Color(0xFF19202E);
  static const Color surfaceHigh = Color(0xFF232A39);
  static const Color surfaceHighest = Color(0xFF2E3544);
  static const Color outline = Color(0xFF3C494E);
  static const Color outlineStrong = Color(0xFF859399);
  static const Color text = Color(0xFFDCE2F6);
  static const Color textMuted = Color(0xFFBBC9CF);
  static const Color textDim = Color(0xFF7C8A9A);
  static const Color cyan = Color(0xFF00D1FF);
  static const Color cyanSoft = Color(0xFFA4E6FF);
  static const Color blue = Color(0xFF0056FD);
  static const Color secondary = Color(0xFFB6C4FF);
  static const Color success = Color(0xFF3DFFC2);
  static const Color warning = Color(0xFFFFC46B);
  static const Color danger = Color(0xFFFF8A80);
}

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
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: ConciergeColors.surfaceHigh.withValues(alpha: 0.96),
      indicatorColor: ConciergeColors.cyan,
      elevation: 0,
      height: 80,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      iconTheme: WidgetStateProperty.resolveWith<IconThemeData?>(
        (states) => IconThemeData(
          color: states.contains(WidgetState.selected)
              ? ConciergeColors.surfaceLowest
              : ConciergeColors.textMuted,
        ),
      ),
      labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>(
        (states) => TextStyle(
          color: states.contains(WidgetState.selected)
              ? ConciergeColors.cyanSoft
              : ConciergeColors.textDim,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
        ),
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
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith<Color?>(
          (states) => states.contains(WidgetState.selected)
              ? ConciergeColors.cyan.withValues(alpha: 0.16)
              : ConciergeColors.surface,
        ),
        foregroundColor: WidgetStateProperty.resolveWith<Color?>(
          (states) => states.contains(WidgetState.selected)
              ? ConciergeColors.cyanSoft
              : ConciergeColors.textMuted,
        ),
        side: WidgetStatePropertyAll(
          BorderSide(color: ConciergeColors.outline.withValues(alpha: 0.6)),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
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
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: ConciergeColors.cyan,
      linearTrackColor: ConciergeColors.surfaceHigh,
      circularTrackColor: ConciergeColors.surfaceHigh,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: ConciergeColors.cyan,
      inactiveTrackColor: ConciergeColors.surfaceHigh,
      thumbColor: ConciergeColors.cyanSoft,
      overlayColor: ConciergeColors.cyan.withValues(alpha: 0.12),
    ),
  );
}

class DartvexLogoMark extends StatelessWidget {
  const DartvexLogoMark({
    super.key,
    this.size = 44,
    this.padding = 0,
    this.glow = false,
  });

  final double size;
  final double padding;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: ConciergeColors.surfaceLowest,
        shape: BoxShape.circle,
        border: Border.all(color: ConciergeColors.cyan.withValues(alpha: 0.24)),
        boxShadow: glow
            ? <BoxShadow>[
                BoxShadow(
                  color: ConciergeColors.cyan.withValues(alpha: 0.22),
                  blurRadius: 28,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: SvgPicture.asset(dartvexLogoAsset, fit: BoxFit.contain),
    );
  }
}

class ConciergeBackground extends StatelessWidget {
  const ConciergeBackground({super.key, required this.child});

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
