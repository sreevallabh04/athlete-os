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

  /// Primary accent (Stark red) for strokes, glows and fills.
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

  TextStyle label({double size = 12, Color? color}) => AppTypography.hudLabel(
    color == null ? textMuted : ink(color),
    size: size,
  );

  TextStyle number({double size = 40, Color? color}) =>
      AppTypography.hudNumber(color == null ? text : ink(color), size: size);

  TextStyle mono({double size = 11, Color? color}) =>
      AppTypography.mono(color == null ? textMuted : ink(color), size: size);

  /// [c] as a text colour. Luminous metric hues (pink, gold, orange…) are
  /// stroke colours: on the porcelain light theme they fall below AA as
  /// text, so bright ones are darkened. Dark theme, neutrals (white on a
  /// filled pill) and colours already dark enough (`accentInk`, `text`) pass
  /// through unchanged.
  Color ink(Color c) {
    if (isDark) return c;
    // Brand hues have hand-tuned light-theme inks.
    if (c == AppColors.red || c == AppColors.redInk) {
      return AppColors.redInkLight;
    }
    if (c == AppColors.gold || c == AppColors.goldLight) {
      return AppColors.goldInk;
    }
    if (c == AppColors.jarvis) return AppColors.jarvisInk;
    if (c.computeLuminance() < 0.18 || HSLColor.fromColor(c).saturation < 0.3) {
      return c;
    }
    return Color.lerp(c, Colors.black, 0.48)!;
  }

  /// JARVIS (AI) cyan for strokes, fills and glows. AI surfaces only.
  Color get jarvis => isDark ? AppColors.jarvis : AppColors.jarvisDeep;

  /// JARVIS cyan legible as text/icons on the canvas.
  Color get jarvisInk => isDark ? AppColors.jarvis : AppColors.jarvisInk;

  static const dark = HudTheme(
    isDark: true,
    canvasTop: AppColors.darkBgAlt,
    canvasBottom: AppColors.darkBg,
    accent: AppColors.red,
    accentInk: AppColors.redInk,
    glassFill: Color(0x0DFFF1E2),
    glassFillStrong: Color(0xC7141316),
    hairline: Color(0xFFF2DCC2),
    text: AppColors.darkText,
    textMuted: AppColors.darkTextMuted,
    gridColor: Color(0x12DD3439),
    nebulaIntensity: 0.8,
    glowStrength: 0.75,
  );

  static const light = HudTheme(
    isDark: false,
    canvasTop: Color(0xFFFBF9F6),
    canvasBottom: AppColors.lightBg,
    accent: Color(0xFFD02A30),
    accentInk: AppColors.redInkLight,
    glassFill: Color(0xCCFFFFFF),
    glassFillStrong: Color(0xEBFFFFFF),
    hairline: Color(0xFF8C7F72),
    text: AppColors.lightText,
    textMuted: AppColors.lightTextMuted,
    gridColor: Color(0x14B4232A),
    nebulaIntensity: 0.3,
    glowStrength: 0.4,
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
