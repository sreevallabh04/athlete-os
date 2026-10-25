import 'package:flutter/material.dart';

/// Design tokens. Use these instead of literal values in feature code.
///
/// The visual language is "JARVIS HUD": a deep-space canvas, arc-reactor cyan
/// as the single primary accent, Stark gold for achievements and hot-rod red
/// for alerts. See `docs/DESIGN.md` for usage rules.
abstract final class AppSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;

  /// Horizontal page gutter.
  static const double gutter = 20;

  /// Minimum interactive target (Material / WCAG 2.5.5).
  static const double touchTarget = 48;
}

abstract final class AppRadii {
  static const double xs = 6;
  static const double sm = 10;
  static const double md = 14;
  static const double lg = 20;
  static const double xl = 28;

  /// Floating dock / pill radius.
  static const double dock = 26;
  static const BorderRadius card = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius chip = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius button = BorderRadius.all(Radius.circular(md));
}

/// Legacy duration tokens (still valid). Prefer `AppMotion` in
/// `core/motion` for new code: it adds curves and springs.
abstract final class AppDurations {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration medium = Duration(milliseconds: 280);
  static const Duration slow = Duration(milliseconds: 600);

  /// Ring sweeps, ticker rolls and other "data arriving" moments.
  static const Duration data = Duration(milliseconds: 900);
}

/// Semantic accent palette. Each metric family has a consistent hue so users
/// learn to associate e.g. green = protein across the whole app.
///
/// Metric hues are tuned for the dark HUD canvas: luminous, slightly
/// desaturated and of similar perceived brightness so no family shouts.
abstract final class AppColors {
  // ── Brand ────────────────────────────────────────────────────────────────
  /// Arc-reactor cyan. The one primary accent: focus, selection, progress.
  static const Color cyan = Color(0xFF36E2FF);

  /// Deeper cyan for fills behind light text and for the light theme.
  static const Color cyanDeep = Color(0xFF00A9D4);

  /// Cyan legible on porcelain (light theme text/icons, AA on white).
  static const Color cyanInk = Color(0xFF007A99);

  /// Stark gold: achievements, streaks, personal records. Use sparingly.
  static const Color gold = Color(0xFFFFC24B);

  /// Hot-rod red: alerts and destructive actions only.
  static const Color red = Color(0xFFFF4D3D);

  /// Primary brand colour (kept for existing call sites) = [cyan].
  static const Color brand = cyan;

  /// Secondary brand colour (kept for existing call sites) = [gold].
  static const Color brandAlt = gold;

  // ── Metric families ──────────────────────────────────────────────────────
  static const Color calories = Color(0xFFFF8F4D);
  static const Color protein = Color(0xFF3EE6A0);
  static const Color carbs = Color(0xFF6E9BFF);
  static const Color fat = Color(0xFFFFCF5C);
  static const Color fiber = Color(0xFFB4EC5A);
  static const Color water = Color(0xFF45C4FF);
  static const Color steps = Color(0xFFB07CFF);
  static const Color heart = Color(0xFFFF5A76);
  static const Color sleep = Color(0xFF8F94FF);
  static const Color strength = Color(0xFFFF72B6);
  static const Color running = Color(0xFFFF6A2B);
  static const Color mood = Color(0xFFFFD84D);
  static const Color habit = Color(0xFF3DE0C8);
  static const Color competition = Color(0xFFE47BFF);

  // ── Status ───────────────────────────────────────────────────────────────
  static const Color success = Color(0xFF3EE68B);
  static const Color warning = Color(0xFFFFB547);
  static const Color danger = red;
  static const Color info = cyan;

  // ── Dark surfaces (deep space) ───────────────────────────────────────────
  /// App canvas. Near-black blue.
  static const Color darkBg = Color(0xFF04060B);

  /// Second canvas stop for vertical gradients.
  static const Color darkBgAlt = Color(0xFF070B14);
  static const Color darkSurface = Color(0xFF0A101B);
  static const Color darkSurfaceHigh = Color(0xFF111A28);
  static const Color darkOutline = Color(0xFF1D2B3D);
  static const Color darkText = Color(0xFFE8F1FA);
  static const Color darkTextMuted = Color(0xFF8EA3B8);

  // ── Light surfaces ("Stark lab" porcelain) ───────────────────────────────
  static const Color lightBg = Color(0xFFF3F5F8);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceHigh = Color(0xFFE9EDF2);
  static const Color lightOutline = Color(0xFFD3DAE3);
  static const Color lightText = Color(0xFF11161D);
  static const Color lightTextMuted = Color(0xFF55606E);
}

abstract final class AppGradients {
  /// Arc-reactor gradient for primary fills and hero accents.
  static const LinearGradient brand = LinearGradient(
    colors: [Color(0xFF36E2FF), Color(0xFF2F7BFF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Stark gold → ember, for achievements.
  static const LinearGradient gold = LinearGradient(
    colors: [Color(0xFFFFD873), Color(0xFFFF9F3D)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient competition = LinearGradient(
    colors: [Color(0xFF7B4DFF), Color(0xFFE47BFF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Deep-space canvas (top → bottom).
  static const LinearGradient canvas = LinearGradient(
    colors: [AppColors.darkBgAlt, AppColors.darkBg],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  /// Soft accent wash used by accent cards.
  static LinearGradient subtle(Color c) => LinearGradient(
    colors: [c.withValues(alpha: 0.16), c.withValues(alpha: 0.03)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Luminous hairline: bright at the top-left "light source", fading out.
  static LinearGradient hairline(Color c, {double strength = 1}) =>
      LinearGradient(
        colors: [
          c.withValues(alpha: (0.42 * strength).clamp(0, 1)),
          c.withValues(alpha: (0.10 * strength).clamp(0, 1)),
          c.withValues(alpha: (0.05 * strength).clamp(0, 1)),
          c.withValues(alpha: (0.16 * strength).clamp(0, 1)),
        ],
        stops: const [0, 0.35, 0.7, 1],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );
}

/// Bloom / glow presets. Glows are zero-offset box shadows tinted with the
/// accent colour: cheap on the GPU and no saveLayer. They use
/// [BlurStyle.outer] so the bloom never shows *through* translucent glass.
abstract final class AppGlows {
  static List<BoxShadow> soft(Color c, {double strength = 1}) => [
    BoxShadow(
      color: c.withValues(alpha: (0.22 * strength).clamp(0, 1)),
      blurRadius: 22,
      blurStyle: BlurStyle.outer,
    ),
  ];

  static List<BoxShadow> strong(Color c, {double strength = 1}) => [
    BoxShadow(
      color: c.withValues(alpha: (0.40 * strength).clamp(0, 1)),
      blurRadius: 14,
      blurStyle: BlurStyle.outer,
    ),
    BoxShadow(
      color: c.withValues(alpha: (0.16 * strength).clamp(0, 1)),
      blurRadius: 36,
      blurStyle: BlurStyle.outer,
    ),
  ];

  /// Text/icon glow (use in `TextStyle.shadows` or `Icon.shadows`).
  static List<Shadow> text(Color c, {double strength = 1}) => [
    Shadow(
      color: c.withValues(alpha: (0.6 * strength).clamp(0, 1)),
      blurRadius: 12,
    ),
  ];
}
