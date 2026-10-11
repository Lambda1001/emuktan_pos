import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../core/format.dart';
import '../../data/held_sales_service.dart';
import '../../data/database.dart';
import '../../domain/cart.dart';
import '../../domain/stock_rules.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/sheet_frame.dart';
import '../stock/stock_screen.dart' show stockProvider;
import 'sell_dialogs.dart' show Discount;

/// Set the current sale aside, with an optional name to recognise it by.
class ParkSaleDialog extends ConsumerStatefulWidget {
  const ParkSaleDialog({
    super.key,
    required this.me,
    required this.lines,
    required this.discount,
  });
  final User me;
  final List<CartLine> lines;
  final Discount? discount;

  @override
  ConsumerState<ParkSaleDialog> createState() => _ParkSaleDialogState();
}

class _ParkSaleDialogState extends ConsumerState<ParkSaleDialog> {
  final _label = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _park() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(heldSalesServiceProvider)
          .park(
            lines: widget.lines,
            userId: widget.me.id,
            label: _label.text,
            discountCents: widget.discount?.cents ?? 0,
            discountApprovedBy: widget.discount?.approverId,
          );
      ref.invalidate(heldSalesProvider);
      if (mounted) Navigator.of(context).pop(true);
    } on HeldSaleException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SheetFrame(
      title: 'Park this sale',
      intro:
          'Set it aside while the customer decides. Stock is not held for it: '
          'prices and stock are checked again when you pick it up.',
      actionLabel: 'Park sale',
      onAction: _park,
      busy: _busy,
      error: _error,
      children: [
        TextField(
          controller: _label,
          autofocus: true,
          maxLength: HeldSalesService.maxLabelLength,
          onSubmitted: (_) => _park(),
          decoration: const InputDecoration(
            labelText: 'Name or note (optional)',
            hintText: 'For example: Mrs Achieng, or blue jacket',
            counterText: '',
          ),
        ),
      ],
    );
  }
}

/// Everything parked, oldest first. Picking one up loads it into the sale.
class ParkedSalesDialog extends ConsumerStatefulWidget {
  const ParkedSalesDialog({super.key, required this.cartIsEmpty});

  /// A parked sale can only be picked up into an empty sale, so nothing the
  /// cashier has already rung up is overwritten.
  final bool cartIsEmpty;

  @override
  ConsumerState<ParkedSalesDialog> createState() => _ParkedSalesDialogState();
}

class _ParkedSalesDialogState extends ConsumerState<ParkedSalesDialog> {
  String? _error;

  Future<void> _resume(HeldSale h) async {
    try {
      final taken = await ref.read(heldSalesServiceProvider).take(h.id);
      ref.invalidate(heldSalesProvider);
      if (mounted) Navigator.of(context).pop(taken);
    } on HeldSaleException catch (e) {
      ref.invalidate(heldSalesProvider);
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _discard(HeldSale h) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => _DiscardDialog(held: h),
    );
    if (ok == true) {
      ref.invalidate(heldSalesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = context.colors;
    final list = ref.watch(heldSalesProvider).value ?? const <HeldSale>[];
    final stock = {
      for (final s in ref.watch(stockProvider).value ?? const <MedicineStock>[])
        s.medicine.id: s,
    };
    final now = DateTime.now();

    return SheetFrame(
      maxWidth: 680,
      title: 'Parked sales',
      intro: list.isEmpty
          ? 'Nothing is parked.'
          : widget.cartIsEmpty
          ? 'Pick one up to carry on with it.'
          : 'Park or finish the current sale before picking one up.',
      actionLabel: '',
      onAction: null,
      cancelLabel: 'Close',
      error: _error,
      children: [
        for (final h in list) ...[
          Builder(
            builder: (context) {
              final quote = quoteCart(h.lines, stock);
              final total = quote.subtotalCents - h.discountCents;
              final sameDay =
                  h.createdAt.year == now.year &&
                  h.createdAt.month == now.month &&
                  h.createdAt.day == now.day;
              final names = [for (final l in quote.lines) l.medicine.name];
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            h.label ?? 'No name',
                            overflow: TextOverflow.ellipsis,
                            style: t.titleMedium!.copyWith(
                              color: h.label == null ? c.textSecondary : null,
                            ),
                          ),
                          Text(
                            '${sameDay ? 'Parked ${formatTime(h.createdAt)}' : 'Parked ${formatDate(h.createdAt)} ${formatTime(h.createdAt)}'}'
                            ' by ${h.parkedByName} · '
                            '${h.lines.length} item${h.lines.length == 1 ? '' : 's'} · '
                            '${formatKes(total)}'
                            '${h.discountCents > 0 ? ' after discount' : ''}',
                            style: t.bodySmall,
                          ),
                          if (names.isNotEmpty)
                            Text(
                              names.take(3).join(', ') +
                                  (names.length > 3
                                      ? ' and ${names.length - 3} more'
                                      : ''),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: t.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Space.md),
                    TextButton(
                      onPressed: () => _discard(h),
                      style: TextButton.styleFrom(foregroundColor: c.critical),
                      child: const Text('Discard'),
                    ),
                    FilledButton.tonal(
                      onPressed: widget.cartIsEmpty ? () => _resume(h) : null,
                      child: const Text('Pick up'),
                    ),
                  ],
                ),
              );
            },
          ),
          const Divider(),
        ],
      ],
    );
  }
}

class _DiscardDialog extends ConsumerStatefulWidget {
  const _DiscardDialog({required this.held});
  final HeldSale held;

  @override
  ConsumerState<_DiscardDialog> createState() => _DiscardDialogState();
}

class _DiscardDialogState extends ConsumerState<_DiscardDialog> {
  bool _busy = false;

  Future<void> _go() async {
    setState(() => _busy = true);
    await ref.read(heldSalesServiceProvider).discard(widget.held.id);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final h = widget.held;
    return SheetFrame(
      title: 'Discard ${h.label ?? 'this parked sale'}?',
      intro:
          'The ${h.lines.length} item${h.lines.length == 1 ? '' : 's'} in it will be forgotten. '
          'Nothing has been sold and no stock was held, so nothing else changes. '
          'This cannot be undone.',
      actionLabel: 'Discard',
      destructive: true,
      busy: _busy,
      onAction: _go,
      children: const [],
    );
  }
}
