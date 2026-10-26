import 'package:flutter/material.dart';

/// Design tokens. Use these instead of literal values in feature code.
///
/// The visual language is "Stark HUD": a warm charcoal canvas, Stark red as
/// the single primary accent, gold for achievements and arc-reactor cyan
/// reserved for JARVIS (AI) surfaces. See `docs/DESIGN.md` for usage rules.
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

/// Semantic accent palette: "Stark" (red & gold).
///
/// * **Stark red** is the one primary accent: selection, progress, primary
///   actions, focus. It accents; it never floods a screen.
/// * **Gold** is earned: achievements, streaks, PRs, "done".
/// * **Arc cyan ([jarvis]) belongs to the AI only**: the orb, AI status,
///   chat, briefing and AI-generated badges. Nothing else may be cyan, so
///   the assistant keeps a distinct identity.
/// * Metric families share one red → gold → titanium family with spaced
///   luminance so adjacent series stay distinguishable (see
///   `test/core/theme_test.dart`).
abstract final class AppColors {
  // ── Brand ────────────────────────────────────────────────────────────────
  /// Stark red. The primary accent (strokes, fills, glows, CTAs).
  static const Color red = Color(0xFFDD3439);

  /// Pressed / deep red: fills behind light text, pressed states.
  static const Color redDeep = Color(0xFFB8262B);

  /// Red legible as text on the charcoal canvas and cards (AA).
  static const Color redInk = Color(0xFFF04A4F);

  /// Red legible as text on porcelain (light theme, AA).
  static const Color redInkLight = Color(0xFFB4232A);

  /// Stark gold: achievements, streaks, personal records, "done".
  static const Color gold = Color(0xFFF2B544);

  /// Light gold for gold text and highlights on dark.
  static const Color goldLight = Color(0xFFFFD27A);

  /// Gold legible as text on porcelain (light theme, AA).
  static const Color goldInk = Color(0xFF8A5A00);

  /// Arc-reactor cyan. **JARVIS / AI surfaces only** (orb, AI status, AI
  /// chat, briefing, AI-generated badges and estimate glyphs).
  static const Color jarvis = Color(0xFF3FD0FF);

  /// Deeper AI cyan for fills behind light text.
  static const Color jarvisDeep = Color(0xFF0E9FCC);

  /// AI cyan legible on porcelain (light theme text/icons, AA).
  static const Color jarvisInk = Color(0xFF006F92);

  /// Legacy alias of [jarvis]. AI surfaces only; prefer [jarvis].
  static const Color cyan = jarvis;

  /// Titanium: neutral information (tags, "auto", disconnected, calendar).
  static const Color titanium = Color(0xFFB7B0A6);

  /// Primary brand colour = [red].
  static const Color brand = red;

  /// Secondary brand colour = [gold].
  static const Color brandAlt = gold;

  // ── Metric families (one warm family + titanium/steel) ───────────────────
  static const Color calories = red;
  static const Color protein = Color(0xFFFFD06E);
  static const Color carbs = Color(0xFFE8822A);
  static const Color fat = Color(0xFFC9466A);
  static const Color fiber = Color(0xFFDCC48A);
  static const Color water = Color(0xFF5F7A90);
  static const Color steps = Color(0xFFDCCDB8);
  static const Color heart = Color(0xFFE85A78);
  static const Color sleep = Color(0xFFB9AE9F);
  static const Color strength = red;
  static const Color running = Color(0xFFF2782F);
  static const Color mood = goldLight;
  static const Color habit = gold;
  static const Color competition = Color(0xFFFF8A3D);

  // ── Status ───────────────────────────────────────────────────────────────
  /// Connected / completed: gold ("done" is earned).
  static const Color success = gold;

  /// Stale, estimate, needs attention. Always paired with a label.
  static const Color warning = Color(0xFFFF9A3D);

  /// Errors, destructive actions and "over target": a hotter coral, brighter
  /// than [red]. Always pair it with an icon and a label, never colour alone.
  static const Color danger = Color(0xFFFF6A4D);

  /// "Over target" (= [danger]).
  static const Color over = danger;
  static const Color info = titanium;

  // ── Dark surfaces (warm charcoal) ────────────────────────────────────────
  /// App canvas (bottom stop).
  static const Color darkBg = Color(0xFF0A0A0C);

  /// Second canvas stop for vertical gradients (top).
  static const Color darkBgAlt = Color(0xFF131215);
  static const Color darkSurface = Color(0xFF151417);
  static const Color darkSurfaceHigh = Color(0xFF1D1B1F);
  static const Color darkOutline = Color(0xFF2E2A2B);
  static const Color darkText = Color(0xFFF4F1EC);
  static const Color darkTextMuted = Color(0xFFA8A299);

  /// Decorative text only (tick labels, disabled): not for content.
  static const Color darkTextFaint = Color(0xFF6A655F);

  // ── Light surfaces ("Stark lab" porcelain) ───────────────────────────────
  static const Color lightBg = Color(0xFFF6F3EE);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceHigh = Color(0xFFECE6DE);
  static const Color lightOutline = Color(0xFFDDD5CB);
  static const Color lightText = Color(0xFF1A1719);
  static const Color lightTextMuted = Color(0xFF5E5850);
}

abstract final class AppGradients {
  /// Stark red gradient for primary fills and hero accents.
  static const LinearGradient brand = LinearGradient(
    colors: [Color(0xFFF0484C), Color(0xFFB8262B)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Stark gold → amber, for achievements.
  static const LinearGradient gold = LinearGradient(
    colors: [Color(0xFFFFD27A), Color(0xFFE8962E)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Red → gold (hot-rod), for competition.
  static const LinearGradient competition = LinearGradient(
    colors: [Color(0xFFDD3439), Color(0xFFF2B544)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Arc-reactor cyan, for JARVIS surfaces only.
  static const LinearGradient jarvis = LinearGradient(
    colors: [Color(0xFF7FE3FF), Color(0xFF0E9FCC)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  /// Charcoal canvas (top → bottom).
  static const LinearGradient canvas = LinearGradient(
    colors: [AppColors.darkBgAlt, AppColors.darkBg],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  /// Soft accent wash used by accent cards.
  static LinearGradient subtle(Color c) => LinearGradient(
    colors: [c.withValues(alpha: 0.13), c.withValues(alpha: 0.02)],
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
