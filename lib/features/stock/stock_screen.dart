import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../core/format.dart';
import '../../data/database.dart';
import '../../data/tables.dart';
import '../../domain/stock_rules.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/error_line.dart';
import 'stock_dialogs.dart';
import 'stock_widgets.dart';

final stockProvider = FutureProvider.autoDispose<List<MedicineStock>>(
  (ref) => ref.watch(stockServiceProvider).listStock(),
);

enum StockFilter { all, low, expiring, expired }

String _filterLabel(StockFilter f) => switch (f) {
  StockFilter.all => 'All',
  StockFilter.low => 'Low stock',
  StockFilter.expiring => 'Expires soon',
  StockFilter.expired => 'Expired',
};

bool _matchesFilter(MedicineStock s, StockFilter f) => switch (f) {
  StockFilter.all => true,
  StockFilter.low => s.isLow,
  StockFilter.expiring => s.expiresSoon,
  StockFilter.expired => s.hasExpired,
};

bool _matchesQuery(MedicineStock s, String q) {
  if (q.isEmpty) return true;
  final needle = q.toLowerCase();
  final m = s.medicine;
  return m.name.toLowerCase().contains(needle) ||
      (m.genericName?.toLowerCase().contains(needle) ?? false) ||
      (m.barcode?.contains(q) ?? false);
}

/// Everyone can look and receive stock. Only the owner adds or edits
/// medicines and adjusts or writes off stock (DESIGN.md section 3).
class StockScreen extends ConsumerStatefulWidget {
  const StockScreen({super.key, required this.me});
  final User me;

  @override
  ConsumerState<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends ConsumerState<StockScreen> {
  final _search = TextEditingController();
  StockFilter _filter = StockFilter.all;

  bool get _isOwner => widget.me.role == Role.owner;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toast(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  Future<void> _dialog(Widget dialog, String done) async {
    final ok = await showDialog<bool>(context: context, builder: (_) => dialog);
    if (ok != true) return;
    ref.invalidate(stockProvider);
    if (mounted) _toast(done);
  }

  @override
  Widget build(BuildContext context) {
    final stock = ref.watch(stockProvider);
    final t = Theme.of(context).textTheme;
    final all = stock.value ?? const <MedicineStock>[];
    final shown = all
        .where(
          (s) =>
              _matchesFilter(s, _filter) &&
              _matchesQuery(s, _search.text.trim()),
        )
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: TextField(
                  controller: _search,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search name or scan barcode',
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
              ),
            ),
            const Spacer(),
            if (_isOwner) ...[
              OutlinedButton.icon(
                onPressed: () => _dialog(
                  MedicineFormDialog(userId: widget.me.id),
                  'Medicine added.',
                ),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add medicine'),
              ),
              const SizedBox(width: Space.md),
            ],
            FilledButton.icon(
              onPressed: all.isEmpty
                  ? null
                  : () => _dialog(
                      ReceiveStockDialog(
                        medicines: [for (final s in all) s.medicine],
                        userId: widget.me.id,
                      ),
                      'Stock received.',
                    ),
              icon: const Icon(Icons.move_to_inbox_outlined, size: 18),
              label: const Text('Receive stock'),
            ),
          ],
        ),
        const SizedBox(height: Space.md),
        SegmentedButton<StockFilter>(
          showSelectedIcon: false,
          segments: [
            for (final f in StockFilter.values)
              ButtonSegment(value: f, label: Text(_filterLabel(f))),
          ],
          selected: {_filter},
          onSelectionChanged: (s) => setState(() => _filter = s.single),
        ),
        const SizedBox(height: Space.lg),
        Expanded(
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: stock.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(Space.xl),
                child: ErrorLine('Could not load stock. $e'),
              ),
              data: (_) => all.isEmpty
                  ? _Empty(
                      title: 'No medicines yet',
                      body: _isOwner
                          ? 'Add your first medicine, then receive stock into it.'
                          : 'The owner needs to add medicines before stock can be received.',
                    )
                  : shown.isEmpty
                  ? _Empty(
                      title: 'Nothing matches',
                      body: 'Try a different name, or choose All.',
                    )
                  : Column(
                      children: [
                        const _Header(),
                        const Divider(),
                        Expanded(
                          child: ListView.separated(
                            itemCount: shown.length,
                            separatorBuilder: (_, _) => const Divider(),
                            itemBuilder: (context, i) => _Row(
                              s: shown[i],
                              isOwner: _isOwner,
                              onReceive: () => _dialog(
                                ReceiveStockDialog(
                                  medicines: [for (final s in all) s.medicine],
                                  initial: shown[i].medicine,
                                  userId: widget.me.id,
                                ),
                                'Stock received.',
                              ),
                              onBatches: () async {
                                await showDialog<bool>(
                                  context: context,
                                  builder: (_) => BatchesDialog(
                                    medicineId: shown[i].medicine.id,
                                    canAdjust: _isOwner,
                                    userId: widget.me.id,
                                  ),
                                );
                                ref.invalidate(stockProvider);
                              },
                              onEdit: () => _dialog(
                                MedicineFormDialog(
                                  existing: shown[i].medicine,
                                  userId: widget.me.id,
                                ),
                                'Changes saved.',
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
        if (stock.hasValue && all.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: Text(
              '${shown.length} of ${all.length} medicines',
              style: t.labelSmall,
            ),
          ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.title, required this.body});
  final String title, body;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 40,
            color: context.colors.textTertiary,
          ),
          const SizedBox(height: Space.md),
          Text(title, style: t.titleMedium),
          const SizedBox(height: Space.xs),
          Text(body, style: t.bodySmall),
        ],
      ),
    );
  }
}

const _pad = EdgeInsets.symmetric(horizontal: Space.lg);

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).textTheme.labelSmall!;
    return Padding(
      padding: _pad,
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            Expanded(flex: 4, child: Text('Medicine', style: s)),
            Expanded(flex: 2, child: Text('In stock', style: s)),
            Expanded(flex: 2, child: Text('Next expiry', style: s)),
            Expanded(flex: 3, child: Text('Selling price', style: s)),
            Expanded(flex: 3, child: Text('Status', style: s)),
            const SizedBox(width: 280),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.s,
    required this.isOwner,
    required this.onReceive,
    required this.onBatches,
    required this.onEdit,
  });
  final MedicineStock s;
  final bool isOwner;
  final VoidCallback onReceive, onBatches, onEdit;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = context.colors;
    final m = s.medicine;
    final prices = [
      for (final mode in offeredModes(m))
        '${modeLabel(mode)} ${formatKes(priceCents(m, mode)!)}',
    ];
    return Padding(
      padding: _pad,
      child: SizedBox(
        height: 60,
        child: Row(
          children: [
            Expanded(
              flex: 4,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.name,
                    overflow: TextOverflow.ellipsis,
                    style: t.titleMedium,
                  ),
                  if (m.genericName != null)
                    Text(
                      m.genericName!,
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
                style: t.bodyMedium,
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                s.nextExpiry == null ? '-' : formatExpiry(s.nextExpiry!),
                style: t.bodyMedium!.copyWith(
                  color: s.nextExpiry == null ? c.textTertiary : null,
                ),
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(prices.join('  '), style: t.bodySmall),
            ),
            Expanded(
              flex: 3,
              child: Wrap(
                spacing: Space.xs,
                runSpacing: Space.xs,
                children: [
                  if (s.onHand == 0)
                    const StatusChip(
                      label: 'Out of stock',
                      icon: Icons.remove_circle_outline,
                      tone: Tone.neutral,
                    )
                  else if (s.isLow)
                    const StatusChip(
                      label: 'Low stock',
                      icon: Icons.south,
                      tone: Tone.warning,
                    )
                  else if (s.sellable > 0)
                    const StatusChip(
                      label: 'In stock',
                      icon: Icons.check_circle_outline,
                      tone: Tone.success,
                    ),
                  if (s.hasExpired)
                    const StatusChip(
                      label: 'Expired',
                      icon: Icons.error_outline,
                      tone: Tone.critical,
                    )
                  else if (s.expiresSoon)
                    const StatusChip(
                      label: 'Expires soon',
                      icon: Icons.schedule,
                      tone: Tone.warning,
                    ),
                ],
              ),
            ),
            SizedBox(
              width: 280,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: onReceive,
                      child: const Text('Receive'),
                    ),
                    TextButton(
                      onPressed: onBatches,
                      child: const Text('Batches'),
                    ),
                    if (isOwner)
                      TextButton(onPressed: onEdit, child: const Text('Edit')),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
