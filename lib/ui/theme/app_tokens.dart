import 'package:flutter/material.dart';

/// Design tokens for Emuktan. Single source of truth: DESIGN.md describes the
/// intent, this file holds the values. Never hard-code a colour, size or radius
/// in a widget; add a token here instead.

/// 4-pt spacing grid.
abstract final class Space {
  static const double xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 32, xxxl = 48;
}

abstract final class Radii {
  static const double control = 8; // buttons, fields, chips
  static const double card = 12; // grouped panels
  static const double sheet = 16; // dialogs and sheets
  static const double pill = 999;
}

/// Minimum interactive sizes. Counter work is mouse + keyboard + scanner, but
/// the PC may have a touchscreen, so the sale flow uses the larger target.
abstract final class Hit {
  static const double standard = 40;
  static const double counter = 48; // Charge, quantity steppers, PIN keys
}

abstract final class Motion {
  static const Duration quick = Duration(milliseconds: 120);
  static const Duration standard = Duration(milliseconds: 200);
  static const Curve curve = Curves.easeOutCubic;
}

/// Type roles, modelled on the Apple HIG hierarchy and sized for a desktop
/// window read at arm's length on a shop counter.
abstract final class TypeScale {
  static const double largeTitle = 28;
  static const double title = 20;
  static const double headline = 15; // semibold
  static const double body = 14;
  static const double callout = 13;
  static const double caption = 12; // smallest size allowed
  static const double amount = 32; // totals at the counter

  static const List<String> fontFallback = [
    'Segoe UI Variable Text',
    'Segoe UI',
    'Arial',
  ];
  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];
}

@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.window,
    required this.surface,
    required this.sidebar,
    required this.separator,
    required this.text,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.success,
    required this.successSoft,
    required this.warning,
    required this.warningSoft,
    required this.critical,
    required this.criticalSoft,
  });

  final Color window, surface, sidebar, separator;
  final Color text, textSecondary, textTertiary;
  final Color accent, onAccent, accentSoft;
  final Color success, successSoft, warning, warningSoft, critical, criticalSoft;

  static const light = AppColors(
    window: Color(0xFFF4F6F8),
    surface: Color(0xFFFFFFFF),
    sidebar: Color(0xFFEBEEF2),
    separator: Color(0xFFD8DDE4),
    text: Color(0xFF14181F),
    textSecondary: Color(0xFF586171),
    textTertiary: Color(0xFF687180),
    accent: Color(0xFF0A64AD),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFE2EFFA),
    success: Color(0xFF18733E),
    successSoft: Color(0xFFE6F5EC),
    warning: Color(0xFF9A5B00),
    warningSoft: Color(0xFFFCEFD6),
    critical: Color(0xFFC62B27),
    criticalSoft: Color(0xFFFBE4E3),
  );

  static const dark = AppColors(
    window: Color(0xFF14171B),
    surface: Color(0xFF1D2127),
    sidebar: Color(0xFF191C21),
    separator: Color(0xFF343A44),
    text: Color(0xFFF1F3F6),
    textSecondary: Color(0xFFA9B1BE),
    textTertiary: Color(0xFF8F98A6),
    accent: Color(0xFF59AEF0),
    onAccent: Color(0xFF0B1520),
    accentSoft: Color(0xFF1B3144),
    success: Color(0xFF4CC27E),
    successSoft: Color(0xFF173626),
    warning: Color(0xFFE8A33B),
    warningSoft: Color(0xFF3B2C12),
    critical: Color(0xFFFF6B63),
    criticalSoft: Color(0xFF412120),
  );

  @override
  AppColors copyWith() => this;

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppColors(
      window: l(window, other.window),
      surface: l(surface, other.surface),
      sidebar: l(sidebar, other.sidebar),
      separator: l(separator, other.separator),
      text: l(text, other.text),
      textSecondary: l(textSecondary, other.textSecondary),
      textTertiary: l(textTertiary, other.textTertiary),
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      accentSoft: l(accentSoft, other.accentSoft),
      success: l(success, other.success),
      successSoft: l(successSoft, other.successSoft),
      warning: l(warning, other.warning),
      warningSoft: l(warningSoft, other.warningSoft),
      critical: l(critical, other.critical),
      criticalSoft: l(criticalSoft, other.criticalSoft),
    );
  }
}

extension AppColorsX on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>()!;
}
