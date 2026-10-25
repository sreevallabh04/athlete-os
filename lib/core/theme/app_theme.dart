import 'package:flutter/material.dart';

import '../motion/page_transitions.dart';
import 'hud_theme.dart';
import 'tokens.dart';
import 'typography.dart';

/// Material theme wired to the HUD tokens. Dark is the hero; light is the
/// "Stark lab" porcelain variant.
abstract final class AppTheme {
  static ThemeData dark() => _build(Brightness.dark);
  static ThemeData light() => _build(Brightness.light);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final hud = isDark ? HudTheme.dark : HudTheme.light;
    final text = isDark ? AppColors.darkText : AppColors.lightText;
    final muted = isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted;
    final primary = isDark ? AppColors.cyan : AppColors.cyanDeep;
    final surface = isDark ? AppColors.darkSurface : AppColors.lightSurface;
    final surfaceHigh = isDark
        ? AppColors.darkSurfaceHigh
        : AppColors.lightSurfaceHigh;
    final outline = isDark ? AppColors.darkOutline : AppColors.lightOutline;

    final scheme =
        ColorScheme.fromSeed(
          seedColor: AppColors.cyan,
          brightness: brightness,
        ).copyWith(
          primary: primary,
          onPrimary: isDark ? const Color(0xFF02141C) : Colors.white,
          primaryContainer: primary.withValues(alpha: isDark ? 0.18 : 0.14),
          onPrimaryContainer: isDark ? AppColors.cyan : AppColors.cyanInk,
          secondary: AppColors.gold,
          onSecondary: const Color(0xFF1F1400),
          secondaryContainer: AppColors.gold.withValues(alpha: 0.18),
          onSecondaryContainer: isDark
              ? AppColors.gold
              : const Color(0xFF6B4A00),
          tertiary: AppColors.protein,
          surface: surface,
          onSurface: text,
          onSurfaceVariant: muted,
          surfaceContainerLowest: isDark
              ? AppColors.darkBg
              : AppColors.lightSurface,
          surfaceContainerLow: isDark
              ? const Color(0xFF080D16)
              : const Color(0xFFF8F9FB),
          surfaceContainer: surface,
          surfaceContainerHigh: isDark
              ? const Color(0xFF0E1622)
              : const Color(0xFFEEF1F5),
          surfaceContainerHighest: surfaceHigh,
          outline: isDark ? const Color(0xFF3A4D63) : const Color(0xFF8A96A5),
          outlineVariant: outline,
          error: AppColors.red,
          onError: Colors.white,
          surfaceTint: Colors.transparent,
          shadow: Colors.black,
          scrim: Colors.black,
        );

    final tt = AppTypography.textTheme(text: text, muted: muted);
    final transitions = PageTransitionsTheme(
      builders: {
        for (final p in TargetPlatform.values)
          p: const HudPageTransitionsBuilder(),
      },
    );

    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      fontFamily: AppFonts.ui,
      textTheme: tt,
      primaryTextTheme: tt,
      // Pages are transparent: the app-wide HudBackground shows through.
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: isDark ? AppColors.darkBg : AppColors.lightBg,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      pageTransitionsTheme: transitions,
      highlightColor: primary.withValues(alpha: 0.06),
      splashColor: primary.withValues(alpha: 0.10),
      hoverColor: primary.withValues(alpha: 0.05),
      focusColor: primary.withValues(alpha: 0.14),
      iconTheme: IconThemeData(color: text, size: 24),
      extensions: [hud],
    );

    final buttonText = tt.labelLarge!.copyWith(letterSpacing: 0.3);
    const buttonShape = RoundedRectangleBorder(borderRadius: AppRadii.button);

    return base.copyWith(
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        foregroundColor: text,
        titleTextStyle: tt.titleLarge,
        iconTheme: IconThemeData(color: text),
        actionsIconTheme: IconThemeData(color: muted),
      ),
      cardTheme: CardThemeData(
        color: isDark ? const Color(0xB30B121E) : Colors.white,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadii.card,
          side: BorderSide(color: hud.hairline.withValues(alpha: 0.16)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: hud.glassFillStrong,
        indicatorColor: primary.withValues(alpha: 0.18),
        surfaceTintColor: Colors.transparent,
        height: 72,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStatePropertyAll(
          tt.labelMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: primary.withValues(alpha: 0.16),
        indicatorShape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
        selectedIconTheme: IconThemeData(color: hud.accentInk),
        unselectedIconTheme: IconThemeData(color: muted),
        selectedLabelTextStyle: tt.labelMedium?.copyWith(
          color: hud.accentInk,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: tt.labelMedium?.copyWith(color: muted),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark
            ? Colors.white.withValues(alpha: 0.04)
            : Colors.white.withValues(alpha: 0.9),
        hintStyle: tt.bodyMedium?.copyWith(color: muted),
        labelStyle: tt.bodyMedium?.copyWith(color: muted),
        floatingLabelStyle: tt.bodySmall?.copyWith(color: hud.accentInk),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide(color: hud.hairline.withValues(alpha: 0.16)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide(color: hud.hairline.withValues(alpha: 0.16)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: BorderSide(color: primary, width: 1.4),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          borderSide: const BorderSide(color: AppColors.red),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md + 2,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 52),
          shape: buttonShape,
          textStyle: buttonText,
          backgroundColor: primary,
          foregroundColor: scheme.onPrimary,
          disabledBackgroundColor: text.withValues(alpha: 0.10),
          disabledForegroundColor: muted,
          // No Material drop shadow: on the dark canvas it reads as a smudge.
          // Use HudButton when a call to action needs bloom.
          elevation: 0,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(64, 52),
          shape: buttonShape,
          textStyle: buttonText,
          backgroundColor: primary.withValues(alpha: 0.14),
          foregroundColor: hud.accentInk,
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 52),
          shape: buttonShape,
          textStyle: buttonText,
          foregroundColor: hud.accentInk,
          side: BorderSide(color: primary.withValues(alpha: 0.5)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: hud.accentInk,
          textStyle: buttonText,
          shape: buttonShape,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: muted,
          highlightColor: primary.withValues(alpha: 0.12),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: scheme.onPrimary,
        elevation: 8,
        highlightElevation: 10,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(18)),
        ),
        extendedTextStyle: buttonText,
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.chip),
        side: BorderSide(color: hud.hairline.withValues(alpha: 0.2)),
        backgroundColor: Colors.white.withValues(alpha: isDark ? 0.03 : 0.7),
        selectedColor: primary.withValues(alpha: 0.18),
        checkmarkColor: hud.accentInk,
        labelStyle: tt.labelLarge,
        secondaryLabelStyle: tt.labelLarge?.copyWith(color: hud.accentInk),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: primary.withValues(alpha: 0.18),
          selectedForegroundColor: hud.accentInk,
          side: BorderSide(color: hud.hairline.withValues(alpha: 0.22)),
          textStyle: tt.labelLarge,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? (isDark ? const Color(0xFFD9FAFF) : Colors.white)
              : muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? primary.withValues(alpha: isDark ? 0.55 : 0.9)
              : text.withValues(alpha: 0.08),
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? primary
              : hud.hairline.withValues(alpha: 0.3),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? primary : null,
        ),
        checkColor: WidgetStatePropertyAll(scheme.onPrimary),
        side: BorderSide(
          color: hud.hairline.withValues(alpha: 0.5),
          width: 1.4,
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(5)),
        ),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? primary : muted,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: primary,
        inactiveTrackColor: primary.withValues(alpha: 0.16),
        thumbColor: isDark ? const Color(0xFFD9FAFF) : primary,
        overlayColor: primary.withValues(alpha: 0.12),
        valueIndicatorColor: surfaceHigh,
        valueIndicatorTextStyle: tt.labelLarge,
        trackHeight: 4,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primary,
        linearTrackColor: primary.withValues(alpha: 0.14),
        circularTrackColor: primary.withValues(alpha: 0.10),
        refreshBackgroundColor: surfaceHigh,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? const Color(0xFF0A111C) : Colors.white,
        modalBackgroundColor: isDark ? const Color(0xFF0A111C) : Colors.white,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: muted.withValues(alpha: 0.5),
        modalBarrierColor: Colors.black.withValues(alpha: 0.55),
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadii.xl),
          ),
          side: BorderSide(color: hud.accent.withValues(alpha: 0.25)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: isDark ? const Color(0xF20B121E) : Colors.white,
        surfaceTintColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.6),
        titleTextStyle: tt.titleLarge,
        contentTextStyle: tt.bodyMedium?.copyWith(color: muted),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.lg),
          side: BorderSide(color: hud.accent.withValues(alpha: 0.25)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: isDark ? const Color(0xF20D1522) : Colors.white,
        surfaceTintColor: Colors.transparent,
        textStyle: tt.bodyMedium,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          side: BorderSide(color: hud.hairline.withValues(alpha: 0.2)),
        ),
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll(
            isDark ? const Color(0xF20D1522) : Colors.white,
          ),
          surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? const Color(0xFF101A28) : AppColors.lightText,
        contentTextStyle: tt.bodyMedium?.copyWith(
          color: isDark ? text : Colors.white,
        ),
        actionTextColor: isDark ? AppColors.cyan : AppColors.cyan,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          side: BorderSide(color: AppColors.cyan.withValues(alpha: 0.3)),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xF2101A28) : AppColors.lightText,
          borderRadius: BorderRadius.circular(AppRadii.xs),
          border: Border.all(color: AppColors.cyan.withValues(alpha: 0.3)),
        ),
        textStyle: tt.labelMedium?.copyWith(
          color: isDark ? text : Colors.white,
        ),
      ),
      dividerTheme: DividerThemeData(
        color: hud.hairline.withValues(alpha: isDark ? 0.10 : 0.18),
        space: 1,
        thickness: 1,
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        minVerticalPadding: AppSpacing.md,
        iconColor: muted,
        textColor: text,
        titleTextStyle: tt.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
        subtitleTextStyle: tt.bodySmall?.copyWith(color: muted),
        shape: const RoundedRectangleBorder(borderRadius: AppRadii.chip),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: hud.accentInk,
        unselectedLabelColor: muted,
        labelStyle: tt.labelLarge,
        unselectedLabelStyle: tt.labelLarge,
        indicatorColor: primary,
        dividerColor: hud.hairline.withValues(alpha: 0.12),
        indicatorSize: TabBarIndicatorSize.label,
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: AppColors.red,
        textColor: Colors.white,
        textStyle: tt.labelSmall,
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: isDark ? const Color(0xFF0B121E) : Colors.white,
        surfaceTintColor: Colors.transparent,
        headerBackgroundColor: isDark
            ? const Color(0xFF0E1826)
            : AppColors.lightSurfaceHigh,
      ),
      timePickerTheme: TimePickerThemeData(
        backgroundColor: isDark ? const Color(0xFF0B121E) : Colors.white,
      ),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: hud.accentInk,
        collapsedIconColor: muted,
        shape: const Border(),
        collapsedShape: const Border(),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: primary,
        selectionColor: primary.withValues(alpha: 0.3),
        selectionHandleColor: primary,
      ),
    );
  }
}
