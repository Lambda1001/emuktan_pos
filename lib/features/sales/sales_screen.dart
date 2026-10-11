import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/format.dart';
import '../../data/database.dart';
import '../../data/sales_admin_service.dart';
import '../../data/tables.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/error_line.dart';
import '../stock/stock_widgets.dart';
import 'sale_dialogs.dart';
import 'sales_providers.dart';

/// Past sales: find one, see it, void it or take items back.
class SalesScreen extends ConsumerStatefulWidget {
  const SalesScreen({super.key, required this.me});
  final User me;

  @override
  ConsumerState<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends ConsumerState<SalesScreen> {
  final _search = TextEditingController();
  int _days = 0; // 0 = today

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _open(SaleSummary s) async {
    await showDialog<void>(
      context: context,
      builder: (_) => SaleDetailDialog(saleId: s.sale.id, me: widget.me),
    );
    ref.invalidate(salesListProvider);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final query = (days: _days, query: _search.text.trim());
    final sales = ref.watch(salesListProvider(query));
    final searching = query.query.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Find by receipt number',
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
          ],
        ),
        const SizedBox(height: Space.md),
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 0, label: Text('Today')),
            ButtonSegment(value: 6, label: Text('Last 7 days')),
            ButtonSegment(value: 29, label: Text('Last 30 days')),
          ],
          selected: {_days},
          onSelectionChanged: searching
              ? null
              : (s) => setState(() => _days = s.single),
        ),
        if (searching)
          Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: Text(
              'Searching all dates. Clear the search to filter by day.',
              style: t.bodySmall,
            ),
          ),
        const SizedBox(height: Space.lg),
        Expanded(
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: sales.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(Space.xl),
                child: ErrorLine('Could not load sales. $e'),
              ),
              data: (list) => list.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.receipt_long_outlined,
                            size: 40,
                            color: context.colors.textTertiary,
                          ),
                          const SizedBox(height: Space.md),
                          Text(
                            searching ? 'No receipt matches' : 'No sales yet',
                            style: t.titleMedium,
                          ),
                          const SizedBox(height: Space.xs),
                          Text(
                            searching
                                ? 'Check the number on the receipt.'
                                : 'Sales made in this period will appear here.',
                            style: t.bodySmall,
                          ),
                        ],
                      ),
                    )
                  : Column(
                      children: [
                        const _Header(),
                        const Divider(),
                        Expanded(
                          child: ListView.separated(
                            itemCount: list.length,
                            separatorBuilder: (_, _) => const Divider(),
                            itemBuilder: (_, i) => _SaleRow(
                              s: list[i],
                              onTap: () => _open(list[i]),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
        sales.maybeWhen(
          data: (list) {
            final taken = list
                .where((s) => s.sale.status == SaleStatus.completed)
                .fold<int>(
                  0,
                  (a, s) => a + s.sale.totalCents - s.refundedCents,
                );
            return Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Text(
                '${list.length} sale${list.length == 1 ? '' : 's'}'
                '${list.isEmpty ? '' : ', ${formatKes(taken, alwaysCents: true)} taken after refunds (voided sales not counted)'}',
                style: t.labelSmall,
              ),
            );
          },
          orElse: () => const SizedBox.shrink(),
        ),
      ],
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
            Expanded(flex: 3, child: Text('Receipt', style: s)),
            Expanded(flex: 2, child: Text('Time', style: s)),
            Expanded(flex: 3, child: Text('Served by', style: s)),
            Expanded(flex: 2, child: Text('Paid by', style: s)),
            Expanded(flex: 2, child: Text('Total', style: s)),
            Expanded(flex: 3, child: Text('Status', style: s)),
          ],
        ),
      ),
    );
  }
}

class _SaleRow extends StatelessWidget {
  const _SaleRow({required this.s, required this.onTap});
  final SaleSummary s;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final sale = s.sale;
    final today = DateTime.now();
    final isToday =
        sale.createdAt.year == today.year &&
        sale.createdAt.month == today.month &&
        sale.createdAt.day == today.day;
    return InkWell(
      onTap: onTap,
      hoverColor: context.colors.separator.withValues(alpha: 0.4),
      child: Padding(
        padding: _pad,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  sale.receiptNo,
                  overflow: TextOverflow.ellipsis,
                  style: t.titleMedium,
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  isToday
                      ? formatTime(sale.createdAt)
                      : '${formatDate(sale.createdAt)} ${formatTime(sale.createdAt)}',
                  overflow: TextOverflow.ellipsis,
                  style: t.bodyMedium,
                ),
              ),
              Expanded(
                flex: 3,
                child: Text(
                  s.cashierName,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodyMedium,
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  s.method == null
                      ? '-'
                      : s.method == PaymentMethod.cash
                      ? 'Cash'
                      : 'M-Pesa',
                  style: t.bodyMedium,
                ),
              ),
              Expanded(
                flex: 2,
                child: Text(
                  formatKes(sale.totalCents),
                  overflow: TextOverflow.ellipsis,
                  style: t.bodyMedium,
                ),
              ),
              Expanded(flex: 3, child: _status()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _status() {
    if (s.sale.status == SaleStatus.voided) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: StatusChip(
          label: 'Voided',
          icon: Icons.block,
          tone: Tone.critical,
        ),
      );
    }
    if (s.refundedCents > 0) {
      return Align(
        alignment: Alignment.centerLeft,
        child: StatusChip(
          label: 'Refunded ${formatKes(s.refundedCents)}',
          icon: Icons.undo,
          tone: Tone.warning,
        ),
      );
    }
    return const Align(
      alignment: Alignment.centerLeft,
      child: StatusChip(
        label: 'Completed',
        icon: Icons.check_circle_outline,
        tone: Tone.success,
      ),
    );
  }
}
