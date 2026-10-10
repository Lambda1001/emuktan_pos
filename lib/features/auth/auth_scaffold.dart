import 'package:flutter/material.dart';

import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/brand_mark.dart';
export '../../ui/widgets/error_line.dart';

/// Centred card used by first-run setup and sign-in.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({super.key, required this.child, this.width = 440});
  final Widget child;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Space.xl),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: width),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const BrandMark(showTagline: true),
                const SizedBox(height: Space.xl),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Space.xl),
                    child: child,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
