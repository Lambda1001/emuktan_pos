import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../core/format.dart';
import '../../data/report_service.dart';
import '../../domain/stock_rules.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/error_line.dart';

enum ReportPeriod { today, week, month, thirtyDays }

String _periodLabel(ReportPeriod p) => switch (p) {
  ReportPeriod.today => 'Today',
  ReportPeriod.week => 'Last 7 days',
  ReportPeriod.month => 'This month',
  ReportPeriod.thirtyDays => 'Last 30 days',
};

/// [from, to) for a period, ending at the end of today.
(DateTime, DateTime) periodRange(ReportPeriod p, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final tomorrow = DateTime(now.year, now.month, now.day + 1);
  return switch (p) {
    ReportPeriod.today => (today, tomorrow),
    ReportPeriod.week => (DateTime(now.year, now.month, now.day - 6), tomorrow),
    ReportPeriod.month => (DateTime(now.year, now.month), tomorrow),
    ReportPeriod.thirtyDays => (
      DateTime(now.year, now.month, now.day - 29),
      tomorrow,
    ),
  };
}

final salesReportProvider = FutureProvider.autoDispose
    .family<SalesReport, ReportPeriod>((ref, p) {
      final (from, to) = periodRange(p, DateTime.now());
      return ref.watch(reportServiceProvider).sales(from: from, to: to);
    });

final stockReportProvider = FutureProvider.autoDispose<StockReport>(
  (ref) => ref.watch(reportServiceProvider).stock(),
);

enum _Tab { sales, stock }

/// Owner-only summaries of sales and stock (DESIGN.md section 3).
class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  _Tab _tab = _Tab.sales;
  ReportPeriod _period = ReportPeriod.today;

  void _copyCsv(SalesReport r) {
    Clipboard.setData(ClipboardData(text: ReportService.salesCsv(r)));
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('Copied. Paste it into Excel or Google Sheets.'),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final report = _tab == _Tab.sales
        ? ref.watch(salesReportProvider(_period)).value
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Space.lg,
          runSpacing: Space.md,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<_Tab>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: _Tab.sales, label: Text('Sales')),
                ButtonSegment(value: _Tab.stock, label: Text('Stock')),
              ],
              selected: {_tab},
              onSelectionChanged: (s) => setState(() => _tab = s.single),
            ),
            if (_tab == _Tab.sales)
              SegmentedButton<ReportPeriod>(
                showSelectedIcon: false,
                segments: [
                  for (final p in ReportPeriod.values)
                    ButtonSegment(value: p, label: Text(_periodLabel(p))),
                ],
                selected: {_period},
                onSelectionChanged: (s) => setState(() => _period = s.single),
              ),
            if (_tab == _Tab.sales)
              OutlinedButton.icon(
                onPressed: report == null ? null : () => _copyCsv(report),
                icon: const Icon(Icons.copy_all_outlined, size: 18),
                label: const Text('Copy for spreadsheet'),
              ),
          ],
        ),
        const SizedBox(height: Space.lg),
        Expanded(
          child: _tab == _Tab.sales
              ? _SalesTab(period: _period)
              : const _StockTab(),
        ),
      ],
    );
  }
}

// ---- Sales ---------------------------------------------------------------

class _SalesTab extends ConsumerWidget {
  const _SalesTab({required this.period});
  final ReportPeriod period;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(salesReportProvider(period))
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorLine('Could not build the report. $e'),
          data: (r) {
            if (r.isEmpty) {
              return _Empty(
                icon: Icons.bar_chart_outlined,
                title: 'No sales in this period',
                body: 'Choose a longer period, or come back after some sales.',
              );
            }
            return ListView(
              children: [
                Wrap(
                  spacing: Space.lg,
                  runSpacing: Space.lg,
                  children: [
                    _Tile('Net sales', formatKes(r.netCents), big: true),
                    _Tile('Sales made', '${r.salesCount}'),
                    _Tile('Cash', formatKes(r.cashCents)),
                    _Tile('M-Pesa', formatKes(r.mpesaCents)),
                    _Tile('Discounts given', formatKes(r.discountCents)),
                    _Tile('Refunds paid', formatKes(r.refundCents)),
                    if (r.voidedCount > 0)
                      _Tile('Cancelled sales', '${r.voidedCount}'),
                  ],
                ),
                const SizedBox(height: Space.xl),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: _Section(
                        title: 'Best sellers',
                        empty: r.topMedicines.isEmpty,
                        header: const ['Medicine', 'Sold', 'Revenue'],
                        rows: [
                          for (final m in r.topMedicines.take(10))
                            [
                              m.medicine.name,
                              quantityText(
                                m.qtyBaseUnits,
                                m.medicine.baseUnitName,
                              ),
                              formatKes(m.revenueCents),
                            ],
                        ],
                      ),
                    ),
                    const SizedBox(width: Space.lg),
                    Expanded(
                      flex: 2,
                      child: Column(
                        children: [
                          _Section(
                            title: 'By day',
                            empty: r.days.isEmpty,
                            header: const ['Day', 'Sales', 'Total'],
                            rows: [
                              for (final d in r.days)
                                [
                                  formatDate(d.day),
                                  '${d.salesCount}',
                                  formatKes(d.totalCents),
                                ],
                            ],
                          ),
                          const SizedBox(height: Space.lg),
                          _Section(
                            title: 'By cashier',
                            empty: r.cashiers.isEmpty,
                            header: const ['Cashier', 'Sales', 'Total'],
                            rows: [
                              for (final c in r.cashiers)
                                [c.name, '${c.salesCount}', formatKes(c.totalCents)],
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
  }
}

// ---- Stock ---------------------------------------------------------------

class _StockTab extends ConsumerWidget {
  const _StockTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(stockReportProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ErrorLine('Could not build the report. $e'),
          data: (r) {
            if (r.medicineCount == 0) {
              return _Empty(
                icon: Icons.inventory_2_outlined,
                title: 'No medicines yet',
                body: 'Add medicines and receive stock to see this report.',
              );
            }
            List<List<String>> names(
              List<MedicineStock> l,
              String Function(MedicineStock) detail,
            ) => [
              for (final s in l) [s.medicine.name, detail(s)],
            ];
            return ListView(
              children: [
                Wrap(
                  spacing: Space.lg,
                  runSpacing: Space.lg,
                  children: [
                    _Tile('Stock value at cost', formatKes(r.valueCents), big: true),
                    _Tile('Medicines', '${r.medicineCount}'),
                    _Tile('Low stock', '${r.low.length}'),
                    _Tile('Out of stock', '${r.outOfStock.length}'),
                    _Tile('Expires soon', '${r.expiringSoon.length}'),
                    _Tile('Expired with stock', '${r.expired.length}'),
                  ],
                ),
                if (r.unpricedBatches > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.sm),
                    child: Text(
                      '${r.unpricedBatches} batch${r.unpricedBatches == 1 ? '' : 'es'} '
                      'with stock have no cost recorded, so the value leaves them out.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                const SizedBox(height: Space.xl),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          _Section(
                            title: 'Expired, remove from shelf',
                            empty: r.expired.isEmpty,
                            emptyText: 'Nothing expired.',
                            header: const ['Medicine', 'Quantity'],
                            rows: names(
                              r.expired,
                              (s) => quantityText(
                                s.expiredQty,
                                s.medicine.baseUnitName,
                              ),
                            ),
                          ),
                          const SizedBox(height: Space.lg),
                          _Section(
                            title: 'Expires soon',
                            empty: r.expiringSoon.isEmpty,
                            emptyText: 'Nothing expires soon.',
                            header: const ['Medicine', 'Next expiry'],
                            rows: names(
                              r.expiringSoon,
                              (s) => s.nextExpiry == null
                                  ? '-'
                                  : formatExpiry(s.nextExpiry!),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Space.lg),
                    Expanded(
                      child: Column(
                        children: [
                          _Section(
                            title: 'Running low',
                            empty: r.low.isEmpty,
                            emptyText: 'Nothing is running low.',
                            header: const ['Medicine', 'Left'],
                            rows: names(
                              r.low,
                              (s) => quantityText(
                                s.onHand,
                                s.medicine.baseUnitName,
                              ),
                            ),
                          ),
                          const SizedBox(height: Space.lg),
                          _Section(
                            title: 'Out of stock',
                            empty: r.outOfStock.isEmpty,
                            emptyText: 'Everything has some stock.',
                            header: const ['Medicine', 'Status'],
                            rows: names(r.outOfStock, (_) => 'Out of stock'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            );
          },
        );
  }
}

// ---- Shared pieces -------------------------------------------------------

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, {this.big = false});
  final String label, value;
  final bool big;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: SizedBox(
        width: big ? 260 : 190,
        child: Padding(
          padding: const EdgeInsets.all(Space.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: t.bodySmall),
              const SizedBox(height: Space.xs),
              Text(
                value,
                style: big ? t.headlineMedium : t.titleLarge,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A titled table. The first column is text; the rest line up to the right.
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.empty,
    required this.header,
    required this.rows,
    this.emptyText = 'Nothing to show.',
  });
  final String title, emptyText;
  final bool empty;
  final List<String> header;
  final List<List<String>> rows;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    Widget line(List<String> cells, TextStyle style) => Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i++)
            i == 0
                ? Expanded(
                    flex: 3,
                    child: Text(
                      cells[i],
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  )
                : Expanded(
                    flex: 2,
                    child: Text(
                      cells[i],
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: style,
                    ),
                  ),
        ],
      ),
    );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: t.titleMedium),
            const SizedBox(height: Space.sm),
            if (empty)
              Text(emptyText, style: t.bodySmall)
            else ...[
              line(header, t.labelSmall!),
              for (final r in rows) ...[
                const Divider(height: 1),
                line(r, t.bodyMedium!),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title, body;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: context.colors.textTertiary),
            const SizedBox(height: Space.md),
            Text(title, style: t.titleMedium),
            const SizedBox(height: Space.xs),
            Text(body, style: t.bodySmall),
          ],
        ),
      ),
    );
  }
}
