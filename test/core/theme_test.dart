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
      expect(
        theme.textTheme.bodyMedium!.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
      expect(theme.scaffoldBackgroundColor, Colors.transparent);
    }
    expect(AppTheme.dark().extension<HudTheme>()!.isDark, isTrue);
    expect(AppTheme.light().extension<HudTheme>()!.isDark, isFalse);
  });

  test('legacy token names still exist and map onto the HUD palette', () {
    expect(AppColors.brand, AppColors.cyan);
    expect(AppColors.brandAlt, AppColors.gold);
    expect(AppColors.danger, AppColors.red);
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
      expect(contrast(AppColors.cyan, bg), greaterThan(4.5));
      expect(contrast(AppColors.gold, bg), greaterThan(4.5));
    }
    for (final bg in [AppColors.lightBg, AppColors.lightSurface]) {
      expect(contrast(AppColors.lightText, bg), greaterThan(7));
      expect(contrast(AppColors.lightTextMuted, bg), greaterThan(4.5));
      expect(contrast(AppColors.cyanInk, bg), greaterThan(4.5));
    }
  });

  test('HudTheme lerps and copies', () {
    final mid = HudTheme.dark.lerp(HudTheme.light, 0.5);
    expect(mid.nebulaIntensity, closeTo(0.675, 1e-9));
    expect(HudTheme.dark.copyWith(glowStrength: 0.2).glowStrength, 0.2);
  });
}
