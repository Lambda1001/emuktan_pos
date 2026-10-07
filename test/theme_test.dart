import 'dart:math' as math;

import 'package:emuktan_pos/ui/theme/app_theme.dart';
import 'package:emuktan_pos/ui/theme/app_tokens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

double _lum(Color c) {
  double f(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
}

double contrast(Color a, Color b) {
  final x = _lum(a), y = _lum(b);
  return (math.max(x, y) + 0.05) / (math.min(x, y) + 0.05);
}

void main() {
  for (final entry in {'light': AppColors.light, 'dark': AppColors.dark}.entries) {
    final c = entry.value;
    group('${entry.key} palette meets WCAG AA (4.5:1) for text', () {
      test('body text on window and surface', () {
        for (final bg in [c.window, c.surface]) {
          for (final fg in [c.text, c.textSecondary, c.textTertiary]) {
            expect(contrast(fg, bg), greaterThanOrEqualTo(4.5), reason: '$fg on $bg');
          }
        }
      });
      test('accent and status colours on surface', () {
        for (final fg in [c.accent, c.success, c.warning, c.critical]) {
          expect(contrast(fg, c.surface), greaterThanOrEqualTo(4.5), reason: '$fg');
        }
      });
      test('status colours on their soft fills', () {
        expect(contrast(c.success, c.successSoft), greaterThanOrEqualTo(4.5));
        expect(contrast(c.warning, c.warningSoft), greaterThanOrEqualTo(4.5));
        expect(contrast(c.critical, c.criticalSoft), greaterThanOrEqualTo(4.5));
        expect(contrast(c.accent, c.accentSoft), greaterThanOrEqualTo(4.5));
      });
      test('label on filled accent button', () {
        expect(contrast(c.onAccent, c.accent), greaterThanOrEqualTo(4.5));
      });
      test('secondary text on sidebar', () {
        expect(contrast(c.textSecondary, c.sidebar), greaterThanOrEqualTo(4.5));
      });
    });
  }

  test('themes build and carry the colour extension', () {
    for (final b in Brightness.values) {
      final t = buildTheme(b);
      expect(t.extension<AppColors>(), isNotNull);
      expect(t.textTheme.bodyMedium!.fontSize, TypeScale.body);
    }
  });

  test('no text style is smaller than the caption size', () {
    final t = buildTheme(Brightness.light).textTheme;
    for (final s in [t.bodySmall, t.labelSmall, t.labelMedium, t.bodyMedium, t.titleMedium]) {
      expect(s!.fontSize!, greaterThanOrEqualTo(TypeScale.caption));
    }
  });
}
