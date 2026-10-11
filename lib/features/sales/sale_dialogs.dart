import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../config/app_config.dart';
import '../../core/format.dart';
import '../../data/sales_admin_service.dart';
import '../../data/database.dart';
import '../../data/tables.dart';
import '../../domain/returns.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/sheet_frame.dart';
import '../stock/stock_screen.dart' show stockProvider;
import '../stock/stock_widgets.dart';
import 'approval.dart';
import 'sales_providers.dart';

String _methodLabel(PaymentMethod m) =>
    m == PaymentMethod.cash ? 'Cash' : 'M-Pesa';

// ---------------------------------------------------------------------------

/// One past sale: what was sold, paid, returned, and the actions on it.
class SaleDetailDialog extends ConsumerWidget {
  const SaleDetailDialog({super.key, required this.saleId, required this.me});
  final int saleId;
  final User me;

  Future<void> _act(
    BuildContext context,
    WidgetRef ref,
    Widget dialog,
    String done,
  ) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => dialog);
    if (ok != true) return;
    ref.invalidate(saleDetailProvider(saleId));
    ref.invalidate(salesListProvider);
    ref.invalidate(stockProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(done)));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(saleDetailProvider(saleId));
    final d = async.value;
    if (d == null) {
      return const Dialog(
        child: Padding(
          padding: EdgeInsets.all(Space.xxl),
          child: SizedBox(
            height: 80,
            child: Center(child: CircularProgressIndicator()),
          ),
        ),
      );
    }
    final t = Theme.of(context).textTheme;
    final c = context.colors;
    final s = d.sale;
    final net = s.totalCents - d.refundedCents;

    return SheetFrame(
      maxWidth: 720,
      title: 'Receipt ${s.receiptNo}',
      intro:
          '${formatDate(s.createdAt)} at ${formatTime(s.createdAt)}, served by ${d.cashierName}.',
      actionLabel: '',
      onAction: null,
      cancelLabel: 'Close',
      extraActions: [
        OutlinedButton(
          onPressed: d.canVoid
              ? () => _act(
                  context,
                  ref,
                  VoidSaleDialog(detail: d, me: me),
                  'Sale ${s.receiptNo} voided.',
                )
              : null,
          style: OutlinedButton.styleFrom(foregroundColor: c.critical),
          child: const Text('Void sale'),
        ),
        FilledButton(
          onPressed: d.canReturn
              ? () => _act(
                  context,
                  ref,
                  ReturnItemsDialog(detail: d, me: me),
                  'Items returned.',
                )
              : null,
          child: const Text('Return items'),
        ),
      ],
      children: [
        if (d.isVoided)
          _Banner(
            icon: Icons.block,
            tone: Tone.critical,
            text:
                'Voided on ${formatDate(s.voidedAt!)} at ${formatTime(s.voidedAt!)}, '
                'approved by ${d.voidedByName ?? 'unknown'}. Reason: ${s.voidReason}',
          )
        else if (!d.canVoid && d.refundedCents > 0)
          _Banner(
            icon: Icons.undo,
            tone: Tone.warning,
            text:
                '${formatKes(d.refundedCents, alwaysCents: true)} has been refunded. '
                'A sale with returns can no longer be voided.',
          ),
        const SizedBox(height: Space.md),
        for (final l in d.lines)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 5,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.medicine.name, style: t.titleMedium),
                      Text(
                        '${quantityText(l.item.qtyBaseUnits, l.medicine.baseUnitName)} · batch ${l.batchNumber}',
                        style: t.bodySmall,
                      ),
                      if (l.returnedQty > 0)
                        Text(
                          '${quantityText(l.returnedQty, l.medicine.baseUnitName)} returned',
                          style: t.bodySmall!.copyWith(color: c.warning),
                        ),
                    ],
                  ),
                ),
                Text(formatKes(l.item.lineTotalCents), style: t.bodyMedium),
              ],
            ),
          ),
        const Divider(height: Space.xl),
        _Row('Subtotal', formatKes(s.subtotalCents)),
        if (s.discountCents > 0)
          _Row(
            'Discount, approved by ${d.discountApproverName ?? 'unknown'}',
            '-${formatKes(s.discountCents)}',
          ),
        _Row('Total', formatKes(s.totalCents, alwaysCents: true), strong: true),
        for (final p in d.payments)
          _Row(
            'Paid by ${_methodLabel(p.method)}'
            '${p.mpesaCode == null ? '' : ', code ${p.mpesaCode}'}',
            formatKes(p.amountCents),
          ),
        if (d.returns.isNotEmpty) ...[
          const Divider(height: Space.xl),
          Text('Returns', style: t.titleMedium),
          const SizedBox(height: Space.sm),
          for (final r in d.returns)
            Padding(
              padding: const EdgeInsets.only(bottom: Space.xs),
              child: Text(
                '${formatDate(r.createdAt)}: '
                '${quantityText(r.qtyBaseUnits, d.lines.firstWhere((l) => l.item.id == r.saleItemId).medicine.baseUnitName)} back, '
                '${formatKes(r.refundCents, alwaysCents: true)} refunded by ${_methodLabel(r.refundMethod)}'
                '${r.restocked ? '' : ' (not restocked)'}. ${r.reason}',
                style: t.bodySmall,
              ),
            ),
          const SizedBox(height: Space.sm),
          _Row(
            'Net after refunds',
            formatKes(net, alwaysCents: true),
            strong: true,
          ),
        ],
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.strong = false});
  final String label, value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: strong ? t.titleMedium : t.bodySmall),
          ),
          Text(value, style: strong ? t.titleMedium : t.bodyMedium),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.tone, required this.text});
  final IconData icon;
  final Tone tone;
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (fg, bg) = tone == Tone.critical
        ? (c.critical, c.criticalSoft)
        : (c.warning, c.warningSoft);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(Radii.control),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Space.md),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: fg),
            const SizedBox(width: Space.sm),
            Expanded(
              child: Text(
                text,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall!.copyWith(color: fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

/// Shared by void and return: the reason, and the approver's PIN if the
/// person at the screen cannot approve for themselves.
mixin _ApprovalFormState<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  final reason = TextEditingController();
  final approverPin = TextEditingController();
  String? error;
  bool busy = false;

  User get me;

  @override
  void dispose() {
    reason.dispose();
    approverPin.dispose();
    super.dispose();
  }

  Widget reasonAndApproval({VoidCallback? onSubmit}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: reason,
        textInputAction: canSelfApprove(me)
            ? TextInputAction.done
            : TextInputAction.next,
        onSubmitted: canSelfApprove(me) ? (_) => onSubmit?.call() : null,
        decoration: const InputDecoration(
          labelText: 'Reason',
          hintText: 'For example: customer changed their mind',
        ),
      ),
      if (!canSelfApprove(me)) ...[
        const SizedBox(height: Space.lg),
        TextField(
          controller: approverPin,
          obscureText: true,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(AppConfig.pinMaxLength),
          ],
          onSubmitted: (_) => onSubmit?.call(),
          decoration: const InputDecoration(
            labelText: 'Approver’s PIN',
            helperText: 'Owner or clinician',
          ),
        ),
      ],
    ],
  );

  /// Runs [action] with the approver resolved, showing rule messages inline.
  Future<void> submit(Future<void> Function(User approver) action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final approver = await resolveApprover(
        ref.read(authServiceProvider),
        me,
        approverPin.text,
      );
      await action(approver);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      final msg = userMessage(e);
      if (msg == null) rethrow;
      approverPin.clear();
      if (mounted) setState(() => error = msg);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

/// Cancel a whole sale.
class VoidSaleDialog extends ConsumerStatefulWidget {
  const VoidSaleDialog({super.key, required this.detail, required this.me});
  final SaleDetail detail;
  final User me;

  @override
  ConsumerState<VoidSaleDialog> createState() => _VoidSaleDialogState();
}

class _VoidSaleDialogState extends ConsumerState<VoidSaleDialog>
    with _ApprovalFormState {
  @override
  User get me => widget.me;

  @override
  Widget build(BuildContext context) {
    final d = widget.detail;
    return SheetFrame(
      title: 'Void sale ${d.sale.receiptNo}?',
      intro:
          'Everything on this sale goes back into stock and the sale is marked voided. '
          'The record is kept and this cannot be undone. '
          'Give ${formatKes(d.sale.totalCents, alwaysCents: true)} back to the customer.',
      actionLabel: 'Void sale',
      destructive: true,
      busy: busy,
      error: error,
      onAction: () => submit(
        (approver) => ref
            .read(salesAdminServiceProvider)
            .voidSale(
              saleId: d.sale.id,
              reason: reason.text,
              approverId: approver.id,
              actingUserId: me.id,
            ),
      ),
      children: [reasonAndApproval()],
    );
  }
}

/// Take some items back and refund them.
class ReturnItemsDialog extends ConsumerStatefulWidget {
  const ReturnItemsDialog({super.key, required this.detail, required this.me});
  final SaleDetail detail;
  final User me;

  @override
  ConsumerState<ReturnItemsDialog> createState() => _ReturnItemsDialogState();
}

class _ReturnItemsDialogState extends ConsumerState<ReturnItemsDialog>
    with _ApprovalFormState {
  @override
  User get me => widget.me;

  late final Map<int, TextEditingController> _qty = {
    for (final l in widget.detail.lines.where((l) => l.remainingQty > 0))
      l.item.id: TextEditingController(),
  };
  late PaymentMethod _method =
      widget.detail.payments.firstOrNull?.method ?? PaymentMethod.cash;
  bool _restock = true;

  @override
  void dispose() {
    for (final c in _qty.values) {
      c.dispose();
    }
    super.dispose();
  }

  int _asked(SaleLine l) => int.tryParse(_qty[l.item.id]?.text ?? '') ?? 0;

  /// Refund for what is typed, or null if any quantity is out of range.
  int? get _refund {
    var total = 0;
    var any = false;
    for (final l in widget.detail.lines) {
      final q = _asked(l);
      if (q == 0) continue;
      if (q < 0 || q > l.remainingQty) return null;
      any = true;
      total += refundFor(
        netCents: l.netCents,
        soldQty: l.item.qtyBaseUnits,
        qty: q,
        alreadyReturned: l.returnedQty,
        alreadyRefunded: l.refundedCents,
      );
    }
    return any ? total : null;
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final d = widget.detail;
    final refund = _refund;
    return SheetFrame(
      maxWidth: 560,
      title: 'Return items from ${d.sale.receiptNo}',
      intro:
          'Enter how many to take back. The refund is what the customer paid for them.',
      actionLabel: refund == null
          ? 'Refund'
          : 'Refund ${formatKes(refund, alwaysCents: true)}',
      busy: busy,
      error: error,
      onAction: refund == null
          ? null
          : () => submit(
              (approver) async => ref
                  .read(salesAdminServiceProvider)
                  .returnItems(
                    saleId: d.sale.id,
                    qtyByItemId: {
                      for (final l in d.lines)
                        if (_asked(l) > 0) l.item.id: _asked(l),
                    },
                    reason: reason.text,
                    approverId: approver.id,
                    actingUserId: me.id,
                    refundMethod: _method,
                    restock: _restock,
                  ),
            ),
      children: [
        for (final l in d.lines.where((l) => l.remainingQty > 0))
          Padding(
            padding: const EdgeInsets.only(bottom: Space.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.medicine.name, style: t.titleMedium),
                      Text(
                        'Batch ${l.batchNumber} · '
                        '${quantityText(l.remainingQty, l.medicine.baseUnitName)} can still be returned',
                        style: t.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Space.md),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: _qty[l.item.id],
                    onChanged: (_) => setState(() => error = null),
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: l.medicine.baseUnitName,
                      errorText: _asked(l) > l.remainingQty
                          ? 'At most ${l.remainingQty}'
                          : null,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(
                    () => _qty[l.item.id]!.text = '${l.remainingQty}',
                  ),
                  child: const Text('All'),
                ),
              ],
            ),
          ),
        const SizedBox(height: Space.sm),
        Text('Refund by', style: t.labelMedium),
        const SizedBox(height: Space.sm),
        SegmentedButton<PaymentMethod>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: PaymentMethod.cash, label: Text('Cash')),
            ButtonSegment(value: PaymentMethod.mpesa, label: Text('M-Pesa')),
          ],
          selected: {_method},
          onSelectionChanged: (s) => setState(() => _method = s.single),
        ),
        CheckboxListTile(
          value: _restock,
          onChanged: (v) => setState(() => _restock = v ?? true),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Put the medicine back in stock'),
          subtitle: const Text(
            'Untick if it is damaged, opened or unsafe to resell.',
          ),
        ),
        const SizedBox(height: Space.md),
        reasonAndApproval(),
      ],
    );
  }
}
