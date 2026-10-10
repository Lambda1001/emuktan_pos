import 'package:flutter/material.dart';

import '../../config/brand.dart';
import '../theme/app_tokens.dart';

/// The logo if one is configured, otherwise the shop name in type.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.height = 48, this.showTagline = false});
  final double height;
  final bool showTagline;

  @override
  Widget build(BuildContext context) {
    final logo = Brand.logoAsset;
    if (logo != null) return Image.asset(logo, height: height);
    final t = Theme.of(context).textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          Brand.name,
          style: t.headlineLarge!.copyWith(color: context.colors.accent),
        ),
        if (showTagline) Text(Brand.tagline, style: t.bodySmall),
      ],
    );
  }
}
