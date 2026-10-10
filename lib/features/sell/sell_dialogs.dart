import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../config/app_config.dart';
import '../../core/format.dart';
import '../../data/auth_service.dart';
import '../../data/database.dart';
import '../../data/sales_service.dart';
import '../../data/tables.dart';
import '../../domain/receipt.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/sheet_frame.dart';

/// A discount the cashier has set and who approved it.
class Discount {
  const Discount({
    required this.cents,
    required this.approverId,
    required this.approverName,
  });
  final int cents;
  final int approverId;
  final String approverName;
}

/// Sets a discount. The owner and clinicians approve their own; a cashier
/// must have one of them type their PIN (DESIGN.md section 8, rule 4).
class DiscountDialog extends ConsumerStatefulWidget {
  const DiscountDialog({
    super.key,
    required this.me,
    required this.subtotalCents,
  });
  final User me;
  final int subtotalCents;

  @override
  ConsumerState<DiscountDialog> createState() => _DiscountDialogState();
}

class _DiscountDialogState extends ConsumerState<DiscountDialog> {
  final _amount = TextEditingController();
  final _pin = TextEditingController();
  String? _error;
  bool _busy = false;

  bool get _canSelfApprove =>
      widget.me.role == Role.owner || widget.me.role == Role.clinician;

  @override
  void dispose() {
    _amount.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _apply() async {
    final cents = parseKes(_amount.text);
    if (cents == null || cents <= 0) {
      setState(() => _error = 'Enter the discount amount. Example: 50');
      return;
    }
    if (cents >= widget.subtotalCents) {
      setState(
        () => _error =
            'The discount must be less than the sale total, '
            '${formatKes(widget.subtotalCents)}.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      User? approver = _canSelfApprove ? widget.me : null;
      if (approver == null) {
        if (_pin.text.isEmpty) {
          setState(
            () => _error = 'Ask the owner or a clinician to enter their PIN.',
          );
          return;
        }
        approver = await ref
            .read(authServiceProvider)
            .verifyApprover(_pin.text);
        if (approver == null) {
          _pin.clear();
          setState(
            () => _error =
                'That PIN is not right. It must be the owner’s or a clinician’s.',
          );
          return;
        }
      }
      if (mounted) {
        Navigator.of(context).pop(
          Discount(
            cents: cents,
            approverId: approver.id,
            approverName: approver.displayName,
          ),
        );
      }
    } on PinLockedException catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SheetFrame(
      title: 'Add a discount',
      intro: _canSelfApprove
          ? 'Sale total ${formatKes(widget.subtotalCents)}. Your approval is recorded on the sale.'
          : 'Sale total ${formatKes(widget.subtotalCents)}. The owner or a clinician must approve it.',
      actionLabel: 'Apply discount',
      onAction: _apply,
      busy: _busy,
      error: _error,
      children: [
        TextField(
          controller: _amount,
          autofocus: true,
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9,.]')),
          ],
          textInputAction: _canSelfApprove
              ? TextInputAction.done
              : TextInputAction.next,
          onSubmitted: _canSelfApprove ? (_) => _apply() : null,
          decoration: const InputDecoration(
            labelText: 'Discount amount',
            prefixText: 'KES ',
          ),
        ),
        if (!_canSelfApprove) ...[
          const SizedBox(height: Space.lg),
          TextField(
            controller: _pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(AppConfig.pinMaxLength),
            ],
            onSubmitted: (_) => _apply(),
            decoration: const InputDecoration(
              labelText: 'Approver’s PIN',
              helperText: 'Owner or clinician',
            ),
          ),
        ],
      ],
    );
  }
}

/// Shown before charging a sale that takes from expired stock. Warn only:
/// the person can go ahead (DESIGN.md decision, Oct 2026).
class ExpiredStockDialog extends StatelessWidget {
  const ExpiredStockDialog({super.key, required this.names});
  final List<String> names;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    color: context.colors.warning,
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      'This sale includes expired stock',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.md),
              Text(
                'Expired medicine should not be sold. This sale takes from expired stock of: ${names.join(', ')}.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: Space.xl),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Go back'),
                  ),
                  const SizedBox(width: Space.md),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    style: FilledButton.styleFrom(
                      backgroundColor: context.colors.critical,
                      foregroundColor: Theme.of(context).colorScheme.onError,
                    ),
                    child: const Text('Sell anyway'),
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

/// The finished sale, laid out as it prints on 80 mm paper.
class ReceiptDialog extends StatelessWidget {
  const ReceiptDialog({super.key, required this.receipt});
  final SaleReceipt receipt;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final text = renderReceipt(receipt);
    return SheetFrame(
      maxWidth: 520,
      title: 'Sale complete',
      intro: receipt.method == PaymentMethod.cash
          ? 'Give the customer ${formatKes(receipt.changeCents, alwaysCents: true)} change.'
          : 'Paid by M-Pesa, code ${receipt.mpesaCode}.',
      actionLabel: 'New sale',
      onAction: () => Navigator.of(context).pop(true),
      cancelLabel: 'Copy receipt',
      cancelPops: false,
      onCancel: () => Clipboard.setData(ClipboardData(text: text)),
      children: [
        Container(
          padding: const EdgeInsets.all(Space.lg),
          decoration: BoxDecoration(
            color: c.window,
            borderRadius: BorderRadius.circular(Radii.control),
            border: Border.all(color: c.separator),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SelectableText(
              text,
              style: TextStyle(
                fontFamily: 'Consolas',
                fontFamilyFallback: const ['Courier New', 'monospace'],
                fontSize: 13,
                height: 1.35,
                color: c.text,
              ),
            ),
          ),
        ),
        const SizedBox(height: Space.sm),
        Text(
          'Receipt printing will be added once the printer is chosen.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
