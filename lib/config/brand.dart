import 'package:flutter/material.dart';

/// Everything that changes when the brand is decided lives in this one file.
///
/// To rebrand:
///  1. Change [name] and the accent colours below.
///  2. Drop the logo into `assets/brand/` and set [logoAsset] (the asset folder
///     is already registered in pubspec.yaml). Leave it null to show [name].
///  3. Run `flutter test`. `test/theme_test.dart` fails if the new accent does
///     not meet WCAG AA (4.5:1) against its background and button text.
abstract final class Brand {
  static const String name = 'Emuktan';

  /// Shown under the name on the sign-in screen and on receipts.
  static const String tagline = 'Dispensary';

  /// e.g. 'assets/brand/logo.png'. Null until the logo is decided.
  static const String? logoAsset = null;

  // Light appearance.
  static const Color accentLight = Color(0xFF0A64AD);
  static const Color onAccentLight = Color(0xFFFFFFFF);
  static const Color accentSoftLight = Color(0xFFE2EFFA);

  // Dark appearance: a lighter tint of the same hue so it reads on dark.
  static const Color accentDark = Color(0xFF59AEF0);
  static const Color onAccentDark = Color(0xFF0B1520);
  static const Color accentSoftDark = Color(0xFF1B3144);
}
