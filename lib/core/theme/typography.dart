import 'package:flutter/material.dart';

/// Bundled font families (see `pubspec.yaml` and `assets/fonts/OFL.txt`).
abstract final class AppFonts {
  /// Inter (opsz 14): body, labels, UI chrome.
  static const ui = 'Inter';

  /// Inter Display (opsz 32): headlines and large numbers.
  static const display = 'InterDisplay';

  /// Rajdhani: technical HUD labels (small caps-style, letter-spaced) and
  /// hero numerals. Use sparingly.
  static const hud = 'Rajdhani';

  /// JetBrains Mono: telemetry readouts, timestamps, boot log lines.
  static const mono = 'JetBrainsMono';
}

/// Type scale.
///
/// Figures: the HUD faces (Rajdhani labels/numerals, JetBrains Mono) are
/// tabular, and [AnimatedTicker] forces tabular figures on whatever style it
/// is given, so changing numbers never jitter. The Inter text styles use
/// proportional figures: Inter's `tnum` also widens the hyphen by ~40 %,
/// which made prose like "heart-rate" or "End-of-day" look letter-spaced.
/// Add [tabular] to an Inter style when a column of numbers must align.
abstract final class AppTypography {
  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  static TextTheme textTheme({required Color text, required Color muted}) {
    TextStyle s(
      String family,
      double size,
      FontWeight w, {
      double ls = 0,
      double h = 1.25,
      Color? color,
    }) => TextStyle(
      fontFamily: family,
      // Display/HUD faces lack some symbols (→ Δ ⟳); fall back to Inter.
      fontFamilyFallback: const [AppFonts.ui],
      fontSize: size,
      fontWeight: w,
      letterSpacing: ls,
      height: h,
      color: color ?? text,
      leadingDistribution: TextLeadingDistribution.even,
    );

    const d = AppFonts.display;
    const u = AppFonts.ui;
    return TextTheme(
      displayLarge: s(d, 56, FontWeight.w800, ls: -1.8, h: 1.05),
      displayMedium: s(d, 44, FontWeight.w800, ls: -1.4, h: 1.08),
      displaySmall: s(d, 36, FontWeight.w700, ls: -1.0, h: 1.1),
      headlineLarge: s(d, 32, FontWeight.w700, ls: -0.8, h: 1.15),
      headlineMedium: s(d, 28, FontWeight.w700, ls: -0.6, h: 1.18),
      headlineSmall: s(d, 24, FontWeight.w700, ls: -0.4, h: 1.2),
      titleLarge: s(u, 20, FontWeight.w600, ls: -0.3, h: 1.25),
      titleMedium: s(u, 16, FontWeight.w600, ls: -0.15, h: 1.3),
      titleSmall: s(u, 14, FontWeight.w600, ls: -0.05, h: 1.3),
      bodyLarge: s(u, 16, FontWeight.w400, ls: -0.1, h: 1.5),
      bodyMedium: s(u, 14, FontWeight.w400, ls: -0.05, h: 1.45),
      bodySmall: s(u, 12.5, FontWeight.w400, h: 1.4, color: muted),
      labelLarge: s(u, 14, FontWeight.w600, ls: 0.05, h: 1.25),
      labelMedium: s(u, 12, FontWeight.w500, ls: 0.15, h: 1.25),
      labelSmall: s(u, 11, FontWeight.w500, ls: 0.3, h: 1.2),
    );
  }

  /// Letter-spaced technical label. Pass UPPERCASE strings.
  static TextStyle hudLabel(Color color, {double size = 12}) => TextStyle(
    fontFamily: AppFonts.hud,
    fontFamilyFallback: const [AppFonts.ui],
    fontSize: size,
    fontWeight: FontWeight.w600,
    letterSpacing: size * 0.16,
    height: 1.1,
    color: color,
    fontFeatures: tabular,
  );

  /// Hero numerals (rings, gauges, countdowns).
  static TextStyle hudNumber(Color color, {double size = 40}) => TextStyle(
    fontFamily: AppFonts.hud,
    fontFamilyFallback: const [AppFonts.ui],
    fontSize: size,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.5,
    height: 1.0,
    color: color,
    fontFeatures: tabular,
  );

  /// Monospace telemetry.
  static TextStyle mono(Color color, {double size = 11}) => TextStyle(
    fontFamily: AppFonts.mono,
    fontFamilyFallback: const [AppFonts.ui],
    fontSize: size,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.2,
    height: 1.35,
    color: color,
  );
}
