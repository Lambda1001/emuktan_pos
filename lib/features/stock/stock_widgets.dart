import 'package:flutter/material.dart';

import '../../domain/stock_rules.dart';
import '../../ui/theme/app_tokens.dart';

enum Tone { success, warning, critical, neutral }

/// Status label: always an icon AND words, never colour alone (DESIGN.md §6).
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.icon,
    required this.tone,
  });
  final String label;
  final IconData icon;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (fg, bg) = switch (tone) {
      Tone.success => (c.success, c.successSoft),
      Tone.warning => (c.warning, c.warningSoft),
      Tone.critical => (c.critical, c.criticalSoft),
      Tone.neutral => (c.textSecondary, c.separator.withValues(alpha: 0.5)),
    };
    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.sm,
          vertical: Space.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: Space.xs),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.labelSmall!.copyWith(color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Chip for one batch's expiry. Nothing is shown when there is nothing to say.
class ExpiryChip extends StatelessWidget {
  const ExpiryChip({super.key, required this.state});
  final ExpiryState state;

  @override
  Widget build(BuildContext context) => switch (state) {
    ExpiryState.expired => const StatusChip(
      label: 'Expired',
      icon: Icons.error_outline,
      tone: Tone.critical,
    ),
    ExpiryState.soon => const StatusChip(
      label: 'Expires soon',
      icon: Icons.schedule,
      tone: Tone.warning,
    ),
    _ => const SizedBox.shrink(),
  };
}
