import 'dart:math' as math;

import 'package:athlete_os/core/theme/app_theme.dart';
import 'package:athlete_os/core/theme/hud_theme.dart';
import 'package:athlete_os/core/theme/tokens.dart';
import 'package:athlete_os/core/theme/typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _lum(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double contrast(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  test('dark and light themes build with the HUD extension and fonts', () {
    for (final theme in [AppTheme.dark(), AppTheme.light()]) {
      final hud = theme.extension<HudTheme>();
      expect(hud, isNotNull);
      expect(theme.textTheme.bodyMedium!.fontFamily, AppFonts.ui);
      expect(theme.textTheme.headlineMedium!.fontFamily, AppFonts.display);
      // Prose uses proportional figures (Inter's tnum widens hyphens);
      // tickers force tabular figures themselves.
      expect(
        theme.textTheme.bodyMedium!.fontFeatures ?? const [],
        isNot(contains(const FontFeature.tabularFigures())),
      );
      expect(theme.scaffoldBackgroundColor, Colors.transparent);
    }
    expect(AppTheme.dark().extension<HudTheme>()!.isDark, isTrue);
    expect(AppTheme.light().extension<HudTheme>()!.isDark, isFalse);
  });

  test('legacy token names still exist and map onto the HUD palette', () {
    expect(AppColors.brand, AppColors.red);
    expect(AppColors.brandAlt, AppColors.gold);
    // Legacy alias: cyan is JARVIS-only now.
    expect(AppColors.cyan, AppColors.jarvis);
    // "Over"/errors are a hotter coral, never the brand red.
    expect(AppColors.over, AppColors.danger);
    expect(AppColors.danger, isNot(AppColors.red));
    expect(AppGradients.subtle(AppColors.protein).colors, hasLength(2));
    expect(AppRadii.card, isA<BorderRadius>());
    expect(AppDurations.slow, greaterThan(AppDurations.fast));
    expect(AppSpacing.gutter, 20);
  });

  test('text colours meet WCAG AA on their surfaces', () {
    // Body + muted text on dark canvas and card surfaces.
    for (final bg in [
      AppColors.darkBg,
      AppColors.darkSurface,
      AppColors.darkSurfaceHigh,
    ]) {
      expect(contrast(AppColors.darkText, bg), greaterThan(7));
      expect(contrast(AppColors.darkTextMuted, bg), greaterThan(4.5));
      expect(contrast(AppColors.redInk, bg), greaterThan(4.5));
      expect(contrast(AppColors.jarvis, bg), greaterThan(4.5));
      expect(contrast(AppColors.gold, bg), greaterThan(4.5));
      expect(contrast(AppColors.danger, bg), greaterThan(4.5));
    }
    for (final bg in [AppColors.lightBg, AppColors.lightSurface]) {
      expect(contrast(AppColors.lightText, bg), greaterThan(7));
      expect(contrast(AppColors.lightTextMuted, bg), greaterThan(4.5));
      expect(contrast(AppColors.redInkLight, bg), greaterThan(4.5));
      expect(contrast(AppColors.jarvisInk, bg), greaterThan(4.5));
      expect(contrast(AppColors.goldInk, bg), greaterThan(4.5));
    }
    // White label on the red primary button.
    expect(contrast(Colors.white, AppColors.red), greaterThan(4.5));
  });

  test('metric strokes read on the canvas and adjacent series separate', () {
    const metrics = [
      AppColors.calories,
      AppColors.protein,
      AppColors.carbs,
      AppColors.fat,
      AppColors.fiber,
      AppColors.water,
      AppColors.steps,
      AppColors.heart,
      AppColors.sleep,
      AppColors.strength,
      AppColors.running,
      AppColors.mood,
      AppColors.habit,
    ];
    for (final c in metrics) {
      // WCAG 1.4.11 non-text contrast on the canvas and on cards.
      expect(contrast(c, AppColors.darkBg), greaterThanOrEqualTo(3));
      expect(contrast(c, AppColors.darkSurfaceHigh), greaterThanOrEqualTo(3));
    }
    // Today's concentric rings (outer → inner) alternate light/dark.
    expect(
      contrast(AppColors.steps, AppColors.calories),
      greaterThanOrEqualTo(2.5),
    );
    expect(
      contrast(AppColors.calories, AppColors.protein),
      greaterThanOrEqualTo(3),
    );
    expect(
      contrast(AppColors.protein, AppColors.water),
      greaterThanOrEqualTo(3),
    );
    // Macro orbit: protein vs fat is the luminance pair; carbs sits between
    // in lightness and hue (and every sector carries its P/C/F letter).
    expect(contrast(AppColors.protein, AppColors.fat), greaterThanOrEqualTo(3));
    expect(
      contrast(AppColors.protein, AppColors.carbs),
      greaterThanOrEqualTo(1.6),
    );
    expect(contrast(AppColors.carbs, AppColors.fat), greaterThanOrEqualTo(1.6));
  });

  test('HudTheme lerps and copies', () {
    final mid = HudTheme.dark.lerp(HudTheme.light, 0.5);
    expect(mid.nebulaIntensity, closeTo(0.55, 1e-9));
    expect(HudTheme.dark.copyWith(glowStrength: 0.2).glowStrength, 0.2);
  });
}
