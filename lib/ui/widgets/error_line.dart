import 'package:flutter/material.dart';

import '../theme/app_tokens.dart';

/// Inline error: icon plus words, never colour alone.
class ErrorLine extends StatelessWidget {
  const ErrorLine(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline, size: 18, color: c.critical),
        const SizedBox(width: Space.sm),
        Expanded(
          child: Text(
            message,
            style: Theme.of(
              context,
            ).textTheme.bodySmall!.copyWith(color: c.critical),
          ),
        ),
      ],
    );
  }
}
