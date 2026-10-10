import 'package:flutter/material.dart';

import 'app_tokens.dart';

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.light ? AppColors.light : AppColors.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.accent,
    onPrimary: c.onAccent,
    secondary: c.accent,
    onSecondary: c.onAccent,
    error: c.critical,
    onError: brightness == Brightness.light
        ? Colors.white
        : const Color(0xFF1A0505),
    surface: c.surface,
    onSurface: c.text,
    outline: c.separator,
    outlineVariant: c.separator,
  );

  TextStyle t(double size, FontWeight w, {Color? color, double? height}) =>
      TextStyle(
        fontFamily: TypeScale.fontFallback.first,
        fontFamilyFallback: TypeScale.fontFallback,
        fontSize: size,
        fontWeight: w,
        height: height ?? 1.35,
        color: color ?? c.text,
        fontFeatures: TypeScale.tabular,
      );

  final text = TextTheme(
    headlineLarge: t(TypeScale.largeTitle, FontWeight.w700, height: 1.2),
    titleLarge: t(TypeScale.title, FontWeight.w600, height: 1.25),
    titleMedium: t(TypeScale.headline, FontWeight.w600),
    bodyLarge: t(TypeScale.body, FontWeight.w400),
    bodyMedium: t(TypeScale.body, FontWeight.w400),
    bodySmall: t(TypeScale.callout, FontWeight.w400, color: c.textSecondary),
    labelLarge: t(TypeScale.body, FontWeight.w600),
    labelMedium: t(TypeScale.callout, FontWeight.w500),
    labelSmall: t(TypeScale.caption, FontWeight.w500, color: c.textSecondary),
    displaySmall: t(TypeScale.amount, FontWeight.w700, height: 1.1),
  );

  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(Radii.control),
  );
  const minSize = Size(64, Hit.standard);
  OutlineInputBorder border(Color color, [double width = 1]) =>
      OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.control),
        borderSide: BorderSide(color: color, width: width),
      );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.window,
    canvasColor: c.window,
    dividerColor: c.separator,
    textTheme: text,
    // HIG: controls change state, they do not ripple.
    splashFactory: NoSplash.splashFactory,
    extensions: [c],
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: minSize,
        shape: shape,
        textStyle: text.labelLarge,
        padding: const EdgeInsets.symmetric(horizontal: Space.lg),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: minSize,
        shape: shape,
        textStyle: text.labelLarge,
        foregroundColor: c.text,
        side: BorderSide(color: c.separator),
        padding: const EdgeInsets.symmetric(horizontal: Space.lg),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: minSize,
        shape: shape,
        textStyle: text.labelLarge,
        foregroundColor: c.accent,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.md,
      ),
      hintStyle: t(TypeScale.body, FontWeight.w400, color: c.textTertiary),
      border: border(c.separator),
      enabledBorder: border(c.separator),
      focusedBorder: border(c.accent, 2),
      errorBorder: border(c.critical),
    ),
    cardTheme: CardThemeData(
      color: c.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: BorderSide(color: c.separator),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surface,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.sheet),
      ),
    ),
    dividerTheme: DividerThemeData(color: c.separator, thickness: 1, space: 1),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: c.text,
        borderRadius: BorderRadius.circular(6),
      ),
      textStyle: t(TypeScale.caption, FontWeight.w500, color: c.surface),
    ),
  );
}
