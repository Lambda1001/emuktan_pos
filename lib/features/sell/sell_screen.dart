import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../core/format.dart';
import '../../data/database.dart';
import '../../data/sales_service.dart';
import '../../data/tables.dart';
import '../../domain/cart.dart';
import '../../domain/stock_rules.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/error_line.dart';
import '../stock/stock_screen.dart' show stockProvider;
import '../stock/stock_widgets.dart';
import 'cart_state.dart';
import 'sell_dialogs.dart';

/// The counter screen: find a medicine, build the sale, take payment.
/// DESIGN.md sections 4 and 8: working area plus a fixed 340 px summary.
class SellScreen extends ConsumerStatefulWidget {
  const SellScreen({super.key, required this.me});
  final User me;

  @override
  ConsumerState<SellScreen> createState() => _SellScreenState();
}

class _SellScreenState extends ConsumerState<SellScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _cash = TextEditingController();
  final _mpesa = TextEditingController();
  Discount? _discount;
  PaymentMethod _method = PaymentMethod.cash;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _cash.dispose();
    _mpesa.dispose();
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

  Future<void> _charge(CartQuote quote, int total) async {
    if (quote.hasExpired) {
      final names = {
        for (final l in quote.lines.where((l) => l.hasExpired)) l.medicine.name,
      }.toList();
      final go = await showDialog<bool>(
        context: context,
        builder: (_) => ExpiredStockDialog(names: names),
      );
      if (go != true) return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final cash = _cash.text.trim().isEmpty ? null : parseKes(_cash.text);
      final receipt = await ref
          .read(salesServiceProvider)
          .completeSale(
            lines: ref.read(cartProvider),
            cashierId: widget.me.id,
            discountCents: _discount?.cents ?? 0,
            discountApprovedBy: _discount?.approverId,
            method: _method,
            cashTenderedCents: cash,
            mpesaCode: _mpesa.text,
          );
      ref.read(cartProvider.notifier).clear();
      ref.invalidate(stockProvider);
      setState(() {
        _discount = null;
        _cash.clear();
        _mpesa.clear();
      });
      if (!mounted) return;
      await showDialog<bool>(
        context: context,
        builder: (_) => ReceiptDialog(receipt: receipt),
      );
      if (mounted) _focusSearch();
    } on SaleRuleException catch (e) {
      ref.invalidate(stockProvider);
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
    final discount = _discount?.cents ?? 0;
    final total = subtotal - discount;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true):
            _focusSearch,
      },
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _workArea(stock, all, quote)),
          const SizedBox(width: Space.lg),
          SizedBox(width: 340, child: _summary(quote, subtotal, total)),
        ],
      ),
    );
  }

  // ---- left: search, results, cart --------------------------------------

  Widget _workArea(
    AsyncValue<List<MedicineStock>> stock,
    List<MedicineStock> all,
    CartQuote quote,
  ) {
    final t = Theme.of(context).textTheme;
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
          flex: 2,
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
                : ListView.separated(
                    itemCount: results.length,
                    separatorBuilder: (_, _) => const Divider(),
                    itemBuilder: (_, i) => _ResultRow(
                      s: results[i],
                      onAdd: () => _add(results[i].medicine),
                    ),
                  ),
          ),
        ),
        const SizedBox(height: Space.md),
        Text('In this sale', style: t.titleMedium),
        const SizedBox(height: Space.sm),
        Expanded(
          flex: 3,
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: quote.lines.isEmpty
                ? const _Hint(
                    icon: Icons.shopping_basket_outlined,
                    title: 'Nothing in the sale yet',
                    body: 'Search or scan a medicine above to add it.',
                  )
                : ListView.separated(
                    itemCount: quote.lines.length,
                    separatorBuilder: (_, _) => const Divider(),
                    itemBuilder: (_, i) {
                      final cart = ref.read(cartProvider.notifier);
                      final l = quote.lines[i];
                      return _CartRow(
                        priced: l,
                        onMode: (m) => cart.setMode(i, m),
                        onCount: (n) => cart.setCount(i, n),
                        onRemove: () => cart.remove(i),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }

  // ---- right: summary and payment ---------------------------------------

  /// Why Charge is off, in words (DESIGN.md section 8, rule 5). Null if it can go.
  String? _whyNot(CartQuote quote, int total) {
    if (quote.lines.isEmpty) return 'Add a medicine to start a sale.';
    if (!quote.isValid) return 'Fix the lines marked in red first.';
    if (_method == PaymentMethod.cash) {
      if (_cash.text.trim().isNotEmpty) {
        final c = parseKes(_cash.text);
        if (c == null) return 'Enter the cash received as an amount.';
        if (c < total) return 'The cash received is less than the total.';
      }
    } else if (_mpesa.text.trim().length < 8) {
      return 'Enter the M-Pesa code from the message.';
    }
    return null;
  }

  Widget _summary(CartQuote quote, int subtotal, int total) {
    final t = Theme.of(context).textTheme;
    final c = context.colors;
    final why = _whyNot(quote, total);
    final cash = parseKes(_cash.text);
    final change = (cash != null && cash >= total) ? cash - total : null;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Sale', style: t.titleLarge),
                    const SizedBox(height: Space.md),
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
                      OutlinedButton.icon(
                        onPressed: quote.isValid
                            ? () => _addDiscount(subtotal)
                            : null,
                        icon: const Icon(Icons.sell_outlined, size: 18),
                        label: const Text('Add discount'),
                      ),
                    const Divider(height: Space.xxl),
                    Text('Total', style: t.bodySmall),
                    Text(
                      formatKes(total),
                      style: t.displaySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: Space.xl),
                    SegmentedButton<PaymentMethod>(
                      showSelectedIcon: false,
                      segments: const [
                        ButtonSegment(
                          value: PaymentMethod.cash,
                          label: Text('Cash'),
                        ),
                        ButtonSegment(
                          value: PaymentMethod.mpesa,
                          label: Text('M-Pesa'),
                        ),
                      ],
                      selected: {_method},
                      onSelectionChanged: (s) => setState(() {
                        _method = s.single;
                        _error = null;
                      }),
                    ),
                    const SizedBox(height: Space.lg),
                    if (_method == PaymentMethod.cash) ...[
                      TextField(
                        controller: _cash,
                        onChanged: (_) => setState(() => _error = null),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9,.]')),
                        ],
                        decoration: InputDecoration(
                          labelText: 'Cash received',
                          prefixText: 'KES ',
                          helperText: 'Leave empty if exact',
                          suffixIcon: TextButton(
                            onPressed: total > 0
                                ? () => setState(
                                    () => _cash.text = (total / 100)
                                        .toStringAsFixed(
                                          total % 100 == 0 ? 0 : 2,
                                        ),
                                  )
                                : null,
                            child: const Text('Exact'),
                          ),
                        ),
                      ),
                      if (change != null) ...[
                        const SizedBox(height: Space.md),
                        _Line(
                          'Change due',
                          formatKes(change, alwaysCents: true),
                          strong: true,
                        ),
                      ],
                    ] else
                      TextField(
                        controller: _mpesa,
                        onChanged: (_) => setState(() => _error = null),
                        textCapitalization: TextCapitalization.characters,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[A-Za-z0-9]'),
                          ),
                          LengthLimitingTextInputFormatter(12),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'M-Pesa transaction code',
                          helperText: 'For example QGH7K2LMNP',
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Space.md),
            if (_error != null) ...[
              ErrorLine(_error!),
              const SizedBox(height: Space.md),
            ],
            FilledButton(
              onPressed: (why == null && !_busy)
                  ? () => _charge(quote, total)
                  : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(Hit.counter),
              ),
              child: Text(
                total > 0 ? 'Charge ${formatKes(total)}' : 'Charge',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (why != null) ...[
              const SizedBox(height: Space.sm),
              Text(why, style: t.bodySmall!.copyWith(color: c.textSecondary)),
            ],
          ],
        ),
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
  const _Line(this.label, this.value, {this.strong = false});
  final String label, value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final style = strong ? t.titleMedium : t.bodyMedium;
    return Row(
      children: [
        Expanded(
          child: Text(label, style: strong ? t.titleMedium : t.bodySmall),
        ),
        Text(value, style: style),
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

/// One medicine in the search results. Click anywhere to add it.
class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.s, required this.onAdd});
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
    ].join('   ');
    return InkWell(
      onTap: out ? null : onAdd,
      hoverColor: c.separator.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.sm,
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.name,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleMedium!.copyWith(
                        color: out ? c.textTertiary : null,
                      ),
                    ),
                    Text(
                      prices,
                      overflow: TextOverflow.ellipsis,
                      style: t.bodySmall,
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  quantityText(s.onHand, m.baseUnitName),
                  style: t.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(
                width: 120,
                child: out
                    ? const StatusChip(
                        label: 'Out of stock',
                        icon: Icons.remove_circle_outline,
                        tone: Tone.neutral,
                      )
                    : s.sellable == 0
                    ? const StatusChip(
                        label: 'Expired',
                        icon: Icons.error_outline,
                        tone: Tone.critical,
                      )
                    : s.isLow
                    ? const StatusChip(
                        label: 'Low stock',
                        icon: Icons.south,
                        tone: Tone.warning,
                      )
                    : const SizedBox.shrink(),
              ),
              Icon(
                Icons.add_circle_outline,
                color: out ? c.textTertiary : c.accent,
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
