import 'package:flutter/material.dart';

import 'tokens.dart';
import 'typography.dart';

/// HUD-specific theme values that Material's [ColorScheme] has no slot for:
/// glass fills, luminous hairlines, glow colour, background intensity and the
/// technical text styles.
///
/// Read with `HudTheme.of(context)` (or the `context.hud` extension).
@immutable
class HudTheme extends ThemeExtension<HudTheme> {
  const HudTheme({
    required this.isDark,
    required this.canvasTop,
    required this.canvasBottom,
    required this.accent,
    required this.accentInk,
    required this.glassFill,
    required this.glassFillStrong,
    required this.hairline,
    required this.text,
    required this.textMuted,
    required this.gridColor,
    required this.nebulaIntensity,
    required this.glowStrength,
  });

  final bool isDark;

  /// Background canvas gradient stops.
  final Color canvasTop;
  final Color canvasBottom;

  /// Primary accent (arc-reactor cyan) for strokes, glows and fills.
  final Color accent;

  /// Accent variant guaranteed legible as text on the canvas.
  final Color accentInk;

  /// Default glass fill (cards).
  final Color glassFill;

  /// Elevated glass (dock, sheets, pinned headers).
  final Color glassFillStrong;

  /// Base hairline colour for 1 px borders.
  final Color hairline;
  final Color text;
  final Color textMuted;

  /// Hex grid / scanline colour (already low alpha).
  final Color gridColor;

  /// 0..1 multiplier for the background nebula.
  final double nebulaIntensity;

  /// 0..1 multiplier applied to every bloom.
  final double glowStrength;

  TextStyle label({double size = 12, Color? color}) =>
      AppTypography.hudLabel(color ?? textMuted, size: size);

  TextStyle number({double size = 40, Color? color}) =>
      AppTypography.hudNumber(color ?? text, size: size);

  TextStyle mono({double size = 11, Color? color}) =>
      AppTypography.mono(color ?? textMuted, size: size);

  static const dark = HudTheme(
    isDark: true,
    canvasTop: AppColors.darkBgAlt,
    canvasBottom: AppColors.darkBg,
    accent: AppColors.cyan,
    accentInk: AppColors.cyan,
    glassFill: Color(0x0FFFFFFF),
    glassFillStrong: Color(0xB80A111D),
    hairline: Color(0xFF9FE9FF),
    text: AppColors.darkText,
    textMuted: AppColors.darkTextMuted,
    gridColor: Color(0x1436E2FF),
    nebulaIntensity: 1,
    glowStrength: 1,
  );

  static const light = HudTheme(
    isDark: false,
    canvasTop: Color(0xFFF7F9FB),
    canvasBottom: AppColors.lightBg,
    accent: AppColors.cyanDeep,
    accentInk: AppColors.cyanInk,
    glassFill: Color(0xC7FFFFFF),
    glassFillStrong: Color(0xE6FFFFFF),
    hairline: Color(0xFF5C7A94),
    text: AppColors.lightText,
    textMuted: AppColors.lightTextMuted,
    gridColor: Color(0x1A007A99),
    nebulaIntensity: 0.35,
    glowStrength: 0.45,
  );

  static HudTheme of(BuildContext context) =>
      Theme.of(context).extension<HudTheme>() ??
      (Theme.of(context).brightness == Brightness.dark ? dark : light);

  @override
  HudTheme copyWith({
    bool? isDark,
    Color? canvasTop,
    Color? canvasBottom,
    Color? accent,
    Color? accentInk,
    Color? glassFill,
    Color? glassFillStrong,
    Color? hairline,
    Color? text,
    Color? textMuted,
    Color? gridColor,
    double? nebulaIntensity,
    double? glowStrength,
  }) => HudTheme(
    isDark: isDark ?? this.isDark,
    canvasTop: canvasTop ?? this.canvasTop,
    canvasBottom: canvasBottom ?? this.canvasBottom,
    accent: accent ?? this.accent,
    accentInk: accentInk ?? this.accentInk,
    glassFill: glassFill ?? this.glassFill,
    glassFillStrong: glassFillStrong ?? this.glassFillStrong,
    hairline: hairline ?? this.hairline,
    text: text ?? this.text,
    textMuted: textMuted ?? this.textMuted,
    gridColor: gridColor ?? this.gridColor,
    nebulaIntensity: nebulaIntensity ?? this.nebulaIntensity,
    glowStrength: glowStrength ?? this.glowStrength,
  );

  @override
  HudTheme lerp(HudTheme? other, double t) {
    if (other == null) return this;
    return HudTheme(
      isDark: t < 0.5 ? isDark : other.isDark,
      canvasTop: Color.lerp(canvasTop, other.canvasTop, t)!,
      canvasBottom: Color.lerp(canvasBottom, other.canvasBottom, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentInk: Color.lerp(accentInk, other.accentInk, t)!,
      glassFill: Color.lerp(glassFill, other.glassFill, t)!,
      glassFillStrong: Color.lerp(glassFillStrong, other.glassFillStrong, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      text: Color.lerp(text, other.text, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      gridColor: Color.lerp(gridColor, other.gridColor, t)!,
      nebulaIntensity:
          nebulaIntensity + (other.nebulaIntensity - nebulaIntensity) * t,
      glowStrength: glowStrength + (other.glowStrength - glowStrength) * t,
    );
  }
}

extension HudThemeContext on BuildContext {
  HudTheme get hud => HudTheme.of(this);
}
