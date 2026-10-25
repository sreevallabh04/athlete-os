import 'package:flutter/material.dart';

/// Design tokens. Use these instead of literal values in feature code.
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
}

abstract final class AppRadii {
  static const double sm = 10;
  static const double md = 16;
  static const double lg = 22;
  static const double xl = 28;
  static const BorderRadius card = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius chip = BorderRadius.all(Radius.circular(sm));
}

abstract final class AppDurations {
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration medium = Duration(milliseconds: 280);
  static const Duration slow = Duration(milliseconds: 600);
}

/// Semantic accent palette. Each metric family has a consistent hue so users
/// learn to associate e.g. green = protein across the whole app.
abstract final class AppColors {
  // Brand
  static const Color brand = Color(0xFF7C5CFF);
  static const Color brandAlt = Color(0xFF00D1B2);

  // Metric families
  static const Color calories = Color(0xFFFF8A3D);
  static const Color protein = Color(0xFF34D399);
  static const Color carbs = Color(0xFF60A5FA);
  static const Color fat = Color(0xFFFBBF24);
  static const Color fiber = Color(0xFFA3E635);
  static const Color water = Color(0xFF38BDF8);
  static const Color steps = Color(0xFF8B5CF6);
  static const Color heart = Color(0xFFF43F5E);
  static const Color sleep = Color(0xFF818CF8);
  static const Color strength = Color(0xFFF472B6);
  static const Color running = Color(0xFFFC5200);
  static const Color mood = Color(0xFFFACC15);
  static const Color habit = Color(0xFF2DD4BF);
  static const Color competition = Color(0xFFE879F9);

  // Status
  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF59E0B);
  static const Color danger = Color(0xFFEF4444);
  static const Color info = Color(0xFF3B82F6);

  // Dark surfaces
  static const Color darkBg = Color(0xFF0B0B10);
  static const Color darkSurface = Color(0xFF14141B);
  static const Color darkSurfaceHigh = Color(0xFF1C1C26);
  static const Color darkOutline = Color(0xFF2A2A36);

  // Light surfaces
  static const Color lightBg = Color(0xFFF6F6FA);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurfaceHigh = Color(0xFFEFEFF5);
  static const Color lightOutline = Color(0xFFDADAE3);
}

abstract final class AppGradients {
  static const LinearGradient brand = LinearGradient(
    colors: [Color(0xFF7C5CFF), Color(0xFF4F8CFF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient competition = LinearGradient(
    colors: [Color(0xFF9333EA), Color(0xFFE879F9)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static LinearGradient subtle(Color c) => LinearGradient(
    colors: [c.withValues(alpha: 0.18), c.withValues(alpha: 0.04)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );
}
