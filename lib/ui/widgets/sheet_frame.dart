import 'package:flutter/material.dart';

import '../../data/auth_service.dart';
import '../../data/stock_service.dart';
import '../theme/app_tokens.dart';
import 'error_line.dart';

/// Rule violations carry a message written for the user. Anything else is a
/// bug and should not be hidden behind a friendly line.
String? userMessage(Object e) =>
    (e is PinPolicyException ||
        e is StaffRuleException ||
        e is StockRuleException)
    ? e.toString()
    : null;

/// The one dialog shape (DESIGN.md section 7, "Sheet"): title, one sentence,
/// the safe button on the left, the action on the right.
class SheetFrame extends StatelessWidget {
  const SheetFrame({
    super.key,
    required this.title,
    required this.intro,
    required this.children,
    required this.actionLabel,
    required this.onAction,
    this.error,
    this.busy = false,
    this.destructive = false,
    this.maxWidth = 440,
    this.cancelLabel = 'Cancel',
    this.cancelPops = true,
    this.onCancel,
    this.extraActions = const [],
  });
  final String title, intro, actionLabel, cancelLabel;
  final List<Widget> children;
  final VoidCallback? onAction;
  final String? error;
  final bool busy, destructive;
  final double maxWidth;

  /// By default the left button closes the sheet. Set [cancelPops] false for
  /// a side action (such as "Copy receipt") that runs [onCancel] and stays.
  final bool cancelPops;
  final VoidCallback? onCancel;

  /// Further buttons between the left button and the main action.
  final List<Widget> extraActions;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = context.colors;
    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: t.titleLarge),
              const SizedBox(height: Space.sm),
              Text(intro, style: t.bodySmall),
              const SizedBox(height: Space.lg),
              ...children,
              if (error != null) ...[
                const SizedBox(height: Space.md),
                ErrorLine(error!),
              ],
              const SizedBox(height: Space.xl),
              // Wraps onto a second line instead of overflowing when labels
              // are long and the sheet is narrow.
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: Space.md,
                runSpacing: Space.sm,
                children: [
                  OutlinedButton(
                    onPressed: busy
                        ? null
                        : () {
                            onCancel?.call();
                            if (cancelPops) Navigator.of(context).pop(false);
                          },
                    child: Text(cancelLabel),
                  ),
                  ...extraActions,
                  // Shown whenever it has a label; a null action means disabled
                  // (for example, nothing chosen yet), not "no button".
                  if (actionLabel.isNotEmpty)
                    FilledButton(
                      onPressed: busy ? null : onAction,
                      style: destructive
                          ? FilledButton.styleFrom(
                              backgroundColor: c.critical,
                              foregroundColor: Theme.of(
                                context,
                              ).colorScheme.onError,
                            )
                          : null,
                      child: Text(actionLabel),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
