import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../core/format.dart';
import '../../data/database.dart';
import '../../data/held_sales_service.dart';
import '../../data/sales_service.dart';
import '../../data/tables.dart';
import '../../domain/cart.dart';
import '../../domain/stock_rules.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/error_line.dart';
import '../patients/patient_picker.dart';
import '../stock/stock_screen.dart' show stockProvider;
import '../stock/stock_widgets.dart';
import 'cart_state.dart';
import 'park_dialogs.dart';
import 'pay_dialog.dart';
import 'sell_dialogs.dart';

/// The counter screen. Products on the left, the sale on the right, and a
/// large payment panel over it when the cashier presses Pay.
/// DESIGN.md sections 4 and 8.
class SellScreen extends ConsumerStatefulWidget {
  const SellScreen({super.key, required this.me});
  final User me;

  @override
  ConsumerState<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends ConsumerState<SellScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  Discount? _discount;
  String? _error;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _focusSearch() {
    _searchFocus.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
  }

  Map<int, MedicineStock> _stockMap(List<MedicineStock> all) => {
    for (final s in all) s.medicine.id: s,
  };

  List<MedicineStock> _results(List<MedicineStock> all) {
    final q = _search.text.trim().toLowerCase();
    return all.where((s) {
      if (offeredModes(s.medicine).isEmpty) return false;
      if (q.isEmpty) return true;
      final m = s.medicine;
      return m.name.toLowerCase().contains(q) ||
          (m.genericName?.toLowerCase().contains(q) ?? false) ||
          (m.barcode?.toLowerCase().contains(q) ?? false);
    }).toList();
  }

  /// Enter in the search box: a scanner sends the barcode then Enter.
  void _onSubmit(List<MedicineStock> all) {
    final q = _search.text.trim();
    if (q.isEmpty) return;
    final exact = all.where((s) => s.medicine.barcode == q).toList();
    final hits = exact.isNotEmpty ? exact : _results(all);
    if (hits.length == 1 && hits.single.onHand > 0) {
      _add(hits.single.medicine);
    } else if (hits.isEmpty) {
      setState(() => _error = 'No medicine matches “$q”.');
    }
  }

  void _add(Medicine m) {
    ref.read(cartProvider.notifier).add(m);
    _search.clear();
    setState(() => _error = null);
    _focusSearch();
  }

  Future<void> _addDiscount(int subtotal) async {
    final d = await showDialog<Discount>(
      context: context,
      builder: (_) => DiscountDialog(me: widget.me, subtotalCents: subtotal),
    );
    if (d != null) setState(() => _discount = d);
  }

  void _toast(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  /// Sets the sale aside and starts a clean one.
  Future<void> _park() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => ParkSaleDialog(
        me: widget.me,
        lines: ref.read(cartProvider),
        discount: _discount,
      ),
    );
    if (ok != true || !mounted) return;
    ref.read(cartProvider.notifier).clear();
    ref.read(cartPatientProvider.notifier).set(null);
    setState(() => _discount = null);
    _toast('Sale parked. Find it under Parked.');
    _focusSearch();
  }

  /// Lists parked sales and loads the one the cashier picks up.
  Future<void> _openParked(CartQuote current) async {
    final picked = await showDialog<HeldSale>(
      context: context,
      builder: (_) => ParkedSalesDialog(cartIsEmpty: current.lines.isEmpty),
    );
    if (picked == null || !mounted) return;

    // Read stock and prices fresh, not from what the screen loaded earlier.
    // Medicines removed since it was parked cannot be sold; say so.
    ref.invalidate(stockProvider);
    final fresh = await ref.read(stockProvider.future);
    if (!mounted) return;
    final known = {for (final s in fresh) s.medicine.id};
    final usable = [
      for (final l in picked.lines)
        if (known.contains(l.medicineId)) l,
    ];
    final dropped = picked.lines.length - usable.length;

    ref.read(cartProvider.notifier).load(usable);
    // The discount was approved for that exact sale: keep it only if nothing
    // changed. The cart listener drops it if it no longer fits the total.
    if (dropped == 0 && picked.discountCents > 0 && picked.approverId != null) {
      setState(
        () => _discount = Discount(
          cents: picked.discountCents,
          approverId: picked.approverId!,
          approverName: picked.approverName ?? 'unknown',
        ),
      );
    }
    _toast(
      dropped > 0
          ? 'Picked up. $dropped item${dropped == 1 ? ' was' : 's were'} removed because the medicine is no longer sold, and the discount was dropped.'
          : 'Picked up${picked.label == null ? '' : ': ${picked.label}'}. Prices and stock are checked again when you pay.',
    );
    _focusSearch();
  }

  /// Pay: confirm expired stock, open the payment panel, then show the receipt.
  Future<void> _pay(CartQuote quote, int subtotal, int total) async {
    if (quote.hasExpired) {
      final names = {
        for (final l in quote.lines.where((l) => l.hasExpired)) l.medicine.name,
      }.toList();
      final go = await showDialog<bool>(
        context: context,
        builder: (_) => ExpiredStockDialog(names: names),
      );
      if (go != true || !mounted) return;
    }
    final receipt = await showDialog<SaleReceipt>(
      context: context,
      builder: (_) => PayDialog(
        me: widget.me,
        lines: ref.read(cartProvider),
        subtotalCents: subtotal,
        discount: _discount,
        totalCents: total,
      ),
    );
    // Whether or not it sold, stock may have moved: show the truth.
    ref.invalidate(stockProvider);
    if (receipt == null) {
      if (mounted) _focusSearch();
      return;
    }
    ref.read(cartProvider.notifier).clear();
    ref.read(cartPatientProvider.notifier).set(null);
    setState(() => _discount = null);
    if (!mounted) return;
    await showDialog<bool>(
      context: context,
      builder: (_) => ReceiptDialog(receipt: receipt),
    );
    if (mounted) _focusSearch();
  }

  @override
  Widget build(BuildContext context) {
    final stock = ref.watch(stockProvider);
    final cart = ref.watch(cartProvider);
    final all = stock.value ?? const <MedicineStock>[];
    final map = _stockMap(all);
    final quote = quoteCart(cart, map);

    // A discount approved for one total must not outlive it.
    ref.listen(cartProvider, (_, next) {
      final d = _discount;
      if (d == null) return;
      final sub = quoteCart(next, map).subtotalCents;
      if (next.isEmpty || d.cents >= sub) {
        setState(() => _discount = null);
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text(
                'The discount was removed because the total changed.',
              ),
            ),
          );
      }
    });

    final subtotal = quote.subtotalCents;
    final total = subtotal - (_discount?.cents ?? 0);

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _focusSearch,
      },
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _catalogue(stock, all)),
          const SizedBox(width: Space.lg),
          SizedBox(width: 440, child: _salePanel(quote, subtotal, total)),
        ],
      ),
    );
  }

  // ---- left: search and product tiles -----------------------------------

  Widget _catalogue(
    AsyncValue<List<MedicineStock>> stock,
    List<MedicineStock> all,
  ) {
    final results = _results(all);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _search,
          focusNode: _searchFocus,
          autofocus: true,
          onChanged: (_) => setState(() => _error = null),
          onSubmitted: (_) => _onSubmit(all),
          decoration: InputDecoration(
            hintText: 'Search name or scan barcode   (Ctrl+K)',
            prefixIcon: const Icon(Icons.search, size: 20),
            suffixIcon: _search.text.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => setState(_search.clear),
                  ),
          ),
        ),
        const SizedBox(height: Space.md),
        Expanded(
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: stock.isLoading
                ? const Center(child: CircularProgressIndicator())
                : all.isEmpty
                ? const _Hint(
                    icon: Icons.inventory_2_outlined,
                    title: 'No medicines yet',
                    body: 'Add medicines and receive stock first (Stock).',
                  )
                : results.isEmpty
                ? _Hint(
                    icon: Icons.search_off,
                    title: 'Nothing matches',
                    body: _error ?? 'Try a different name or barcode.',
                  )
                : GridView.builder(
                    padding: const EdgeInsets.all(Space.md),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 240,
                          mainAxisExtent: 140,
                          crossAxisSpacing: Space.md,
                          mainAxisSpacing: Space.md,
                        ),
                    itemCount: results.length,
                    itemBuilder: (_, i) => _ProductTile(
                      s: results[i],
                      onAdd: () => _add(results[i].medicine),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  // ---- right: the sale ---------------------------------------------------

  Widget _salePanel(CartQuote quote, int subtotal, int total) {
    final t = Theme.of(context).textTheme;
    final c = context.colors;
    final cart = ref.read(cartProvider.notifier);
    final why = quote.lines.isEmpty
        ? 'Add a medicine to start a sale.'
        : !quote.isValid
        ? 'Fix the lines marked in red first.'
        : null;
    final items = quote.lines.length;
    final parked = ref.watch(heldSalesProvider).value?.length ?? 0;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.lg,
              Space.md,
              Space.sm,
              Space.md,
            ),
            child: Row(
              children: [
                Text('Sale', style: t.titleLarge),
                const SizedBox(width: Space.sm),
                if (items > 0)
                  Text(
                    '$items item${items == 1 ? '' : 's'}',
                    style: t.bodySmall,
                  ),
                const Spacer(),
                if (items > 0)
                  TextButton(
                    onPressed: () {
                      cart.clear();
                      ref.read(cartPatientProvider.notifier).set(null);
                      setState(() => _discount = null);
                    },
                    child: const Text('Clear sale'),
                  ),
              ],
            ),
          ),
          _PatientRow(me: widget.me),
          if (items > 0 || parked > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.lg,
                0,
                Space.lg,
                Space.md,
              ),
              child: Wrap(
                spacing: Space.sm,
                runSpacing: Space.sm,
                children: [
                  if (items > 0)
                    OutlinedButton.icon(
                      onPressed: () => _park(),
                      icon: const Icon(Icons.pause_circle_outline, size: 18),
                      label: const Text('Park sale'),
                    ),
                  if (parked > 0)
                    OutlinedButton.icon(
                      onPressed: () => _openParked(quote),
                      icon: const Icon(Icons.history, size: 18),
                      label: Text('Parked ($parked)'),
                    ),
                ],
              ),
            ),
          const Divider(),
          Expanded(
            child: quote.lines.isEmpty
                ? const _Hint(
                    icon: Icons.shopping_basket_outlined,
                    title: 'Nothing in the sale yet',
                    body: 'Click a medicine, or scan it, to add it.',
                  )
                : ListView.separated(
                    itemCount: quote.lines.length,
                    separatorBuilder: (_, _) => const Divider(),
                    itemBuilder: (_, i) => _CartRow(
                      priced: quote.lines[i],
                      onMode: (m) => cart.setMode(i, m),
                      onCount: (n) => cart.setCount(i, n),
                      onRemove: () => cart.remove(i),
                    ),
                  ),
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.all(Space.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (quote.hasExpired) ...[
                  const _Notice(
                    'This sale includes expired stock.',
                    tone: Tone.warning,
                    icon: Icons.warning_amber_rounded,
                  ),
                  const SizedBox(height: Space.md),
                ],
                _Line('Subtotal', formatKes(subtotal)),
                const SizedBox(height: Space.sm),
                if (_discount != null)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Discount, approved by ${_discount!.approverName}',
                          style: t.bodySmall,
                        ),
                      ),
                      Text(
                        '-${formatKes(_discount!.cents)}',
                        style: t.bodyMedium,
                      ),
                      TextButton(
                        onPressed: () => setState(() => _discount = null),
                        child: const Text('Remove'),
                      ),
                    ],
                  )
                else
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: quote.isValid
                          ? () => _addDiscount(subtotal)
                          : null,
                      icon: const Icon(Icons.sell_outlined, size: 18),
                      label: const Text('Add discount'),
                    ),
                  ),
                const SizedBox(height: Space.sm),
                Text('Total', style: t.bodySmall),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(formatKes(total), style: t.displaySmall),
                ),
                const SizedBox(height: Space.md),
                FilledButton(
                  onPressed: why == null
                      ? () => _pay(quote, subtotal, total)
                      : null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(Hit.counter),
                  ),
                  child: Text(
                    total > 0 ? 'Pay ${formatKes(total)}' : 'Pay',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (why != null) ...[
                  const SizedBox(height: Space.sm),
                  Text(
                    why,
                    style: t.bodySmall!.copyWith(color: c.textSecondary),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _Hint extends StatelessWidget {
  const _Hint({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title, body;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 36, color: context.colors.textTertiary),
            const SizedBox(height: Space.sm),
            Text(title, style: t.titleMedium),
            const SizedBox(height: Space.xs),
            Text(body, style: t.bodySmall, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);
  final String label, value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(child: Text(label, style: t.bodySmall)),
        Text(value, style: t.bodyMedium),
      ],
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice(this.text, {required this.tone, required this.icon});
  final String text;
  final Tone tone;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final (fg, bg) = switch (tone) {
      Tone.critical => (c.critical, c.criticalSoft),
      _ => (c.warning, c.warningSoft),
    };
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

/// One medicine to click. Text only: name, price, and what is in stock.
class _ProductTile extends StatelessWidget {
  const _ProductTile({required this.s, required this.onAdd});
  final MedicineStock s;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = context.colors;
    final m = s.medicine;
    final out = s.onHand == 0;
    final prices = [
      for (final mode in offeredModes(m))
        '${modeLabel(mode)} ${formatKes(priceCents(m, mode)!)}',
    ].join('  ');

    return Material(
      color: out ? c.window : c.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.card),
        side: BorderSide(color: c.separator),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: out ? null : onAdd,
        hoverColor: c.accentSoft,
        focusColor: c.accent.withValues(alpha: 0.16),
        child: Padding(
          padding: const EdgeInsets.all(Space.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                m.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: t.titleMedium!.copyWith(
                  color: out ? c.textTertiary : null,
                ),
              ),
              const SizedBox(height: Space.xs),
              Text(
                prices,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: t.bodySmall,
              ),
              const Spacer(),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      quantityText(s.onHand, m.baseUnitName),
                      overflow: TextOverflow.ellipsis,
                      style: t.labelSmall,
                    ),
                  ),
                  if (out)
                    const StatusChip(
                      label: 'Out',
                      icon: Icons.remove_circle_outline,
                      tone: Tone.neutral,
                    )
                  else if (s.sellable == 0)
                    const StatusChip(
                      label: 'Expired',
                      icon: Icons.error_outline,
                      tone: Tone.critical,
                    )
                  else if (s.isLow)
                    const StatusChip(
                      label: 'Low',
                      icon: Icons.south,
                      tone: Tone.warning,
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

/// One line in the sale: what, how it is sold, how many, and any warning.
class _CartRow extends StatelessWidget {
  const _CartRow({
    required this.priced,
    required this.onMode,
    required this.onCount,
    required this.onRemove,
  });
  final PricedLine priced;
  final ValueChanged<PriceMode> onMode;
  final ValueChanged<int> onCount;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = context.colors;
    final m = priced.medicine;
    final line = priced.line;
    final modes = offeredModes(m);

    final what = line.mode == PriceMode.unit
        ? quantityText(line.count, m.baseUnitName)
        : '${line.count} ${modeLabel(line.mode).toLowerCase()}${line.count == 1 ? '' : 's'}'
              ' = ${quantityText(priced.baseQty, m.baseUnitName)}';
    final first = priced.allocations.isEmpty ? null : priced.allocations.first;
    final batchText = first == null
        ? null
        : 'Batch ${first.batchNumber}'
              '${first.expiry == null ? '' : ', expires ${formatExpiry(first.expiry!)}'}'
              '${priced.allocations.length > 1 ? ' (+${priced.allocations.length - 1} more)' : ''}';

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  m.name,
                  overflow: TextOverflow.ellipsis,
                  style: t.titleMedium,
                ),
              ),
              Text(
                priced.notSoldThisWay ? '-' : formatKes(priced.totalCents),
                style: t.titleMedium,
              ),
              IconButton(
                tooltip: 'Remove from sale',
                onPressed: onRemove,
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: Space.lg,
            runSpacing: Space.sm,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (modes.length > 1)
                SegmentedButton<PriceMode>(
                  showSelectedIcon: false,
                  segments: [
                    for (final x in modes)
                      ButtonSegment(value: x, label: Text(modeLabel(x))),
                  ],
                  selected: {
                    modes.contains(line.mode) ? line.mode : modes.first,
                  },
                  onSelectionChanged: (s) => onMode(s.single),
                ),
              _Stepper(count: line.count, onChanged: onCount),
              Text(what, style: t.bodyMedium),
            ],
          ),
          if (batchText != null) ...[
            const SizedBox(height: Space.xs),
            Text(batchText, style: t.bodySmall),
          ],
          if (priced.notSoldThisWay) ...[
            const SizedBox(height: Space.sm),
            const ErrorLine(
              'This medicine is no longer sold this way. Remove it and add it again.',
            ),
          ] else if (priced.shortBy > 0) ...[
            const SizedBox(height: Space.sm),
            ErrorLine(
              priced.baseQty - priced.shortBy == 0
                  ? 'None in stock.'
                  : 'Only ${quantityText(priced.baseQty - priced.shortBy, m.baseUnitName)} in stock. Lower the quantity.',
            ),
          ],
          if (priced.hasExpired) ...[
            const SizedBox(height: Space.sm),
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, size: 18, color: c.warning),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(
                    'Expired. Do not sell. '
                    '${priced.allocations.where((a) => a.expired).map((a) => 'Batch ${a.batchNumber}${a.expiry == null ? '' : ' expired ${formatExpiry(a.expiry!)}'}').join(', ')}.',
                    style: t.bodySmall!.copyWith(color: c.warning),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.count, required this.onChanged});
  final int count;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.outlined(
          tooltip: 'One fewer',
          onPressed: count > 1 ? () => onChanged(count - 1) : null,
          icon: const Icon(Icons.remove),
          constraints: const BoxConstraints.tightFor(
            width: Hit.counter,
            height: Hit.counter,
          ),
        ),
        SizedBox(
          width: 56,
          child: Text(
            '$count',
            textAlign: TextAlign.center,
            style: t.titleMedium,
          ),
        ),
        IconButton.outlined(
          tooltip: 'One more',
          onPressed: () => onChanged(count + 1),
          icon: const Icon(Icons.add),
          constraints: const BoxConstraints.tightFor(
            width: Hit.counter,
            height: Hit.counter,
          ),
        ),
      ],
    );
  }
}

/// Who the sale is for: a button to choose a patient, or their name with
/// a way to change it. Optional; walk-in sales need no patient.
class _PatientRow extends ConsumerWidget {
  const _PatientRow({required this.me});
  final User me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final patient = ref.watch(cartPatientProvider);
    final t = Theme.of(context).textTheme;

    Future<void> choose() async {
      final p = await showDialog<Patient>(
        context: context,
        builder: (_) => PatientPickerDialog(me: me),
      );
      if (p != null) ref.read(cartPatientProvider.notifier).set(p);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.sm, Space.sm),
      child: Row(
        children: [
          Icon(
            Icons.person_outline,
            size: 18,
            color: context.colors.textSecondary,
          ),
          const SizedBox(width: Space.sm),
          if (patient == null)
            TextButton(onPressed: choose, child: const Text('Add patient'))
          else ...[
            Flexible(
              child: Text(
                patient.fullName,
                overflow: TextOverflow.ellipsis,
                style: t.labelLarge,
              ),
            ),
            TextButton(onPressed: choose, child: const Text('Change')),
            IconButton(
              tooltip: 'Remove patient',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () =>
                  ref.read(cartPatientProvider.notifier).set(null),
            ),
          ],
        ],
      ),
    );
  }
}
