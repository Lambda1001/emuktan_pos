import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../core/format.dart';
import '../../data/database.dart';
import '../../data/stock_service.dart';
import '../../data/tables.dart';
import '../../domain/stock_rules.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/sheet_frame.dart';
import 'stock_screen.dart' show stockProvider;
import 'stock_widgets.dart';

int? _intOrNull(String s) => int.tryParse(s.trim().replaceAll(',', ''));

/// Whole-number fields: digits only.
final _digits = [FilteringTextInputFormatter.allow(RegExp(r'[0-9,]'))];

/// Money fields: digits, comma, one decimal point.
final _money = [FilteringTextInputFormatter.allow(RegExp(r'[0-9,.]'))];

// ---------------------------------------------------------------------------

/// Owner: add a medicine, or edit one ([existing]).
class MedicineFormDialog extends ConsumerStatefulWidget {
  const MedicineFormDialog({super.key, this.existing, required this.userId});
  final Medicine? existing;
  final int userId;

  @override
  ConsumerState<MedicineFormDialog> createState() => _MedicineFormDialogState();
}

class _MedicineFormDialogState extends ConsumerState<MedicineFormDialog> {
  late final Medicine? m = widget.existing;
  late final _name = TextEditingController(text: m?.name);
  late final _generic = TextEditingController(text: m?.genericName);
  late final _barcode = TextEditingController(text: m?.barcode);
  late final _unit = TextEditingController(text: m?.baseUnitName ?? 'tablet');
  late final _perStrip = TextEditingController(
    text: m?.unitsPerStrip?.toString(),
  );
  late final _perPack = TextEditingController(
    text: m?.unitsPerPack?.toString(),
  );
  late final _pricePack = TextEditingController(
    text: _kes(m?.pricePerPackCents),
  );
  late final _priceStrip = TextEditingController(
    text: _kes(m?.pricePerStripCents),
  );
  late final _priceUnit = TextEditingController(
    text: _kes(m?.pricePerUnitCents),
  );
  late final _low = TextEditingController(
    text: (m?.lowStockThreshold ?? 0) == 0
        ? ''
        : m!.lowStockThreshold.toString(),
  );
  String? _error;
  bool _busy = false;

  static String? _kes(int? cents) {
    if (cents == null) return null;
    return cents % 100 == 0
        ? (cents ~/ 100).toString()
        : '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _generic,
      _barcode,
      _unit,
      _perStrip,
      _perPack,
      _pricePack,
      _priceStrip,
      _priceUnit,
      _low,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Empty means "not offered"; anything else must parse.
  int? _optInt(TextEditingController c, String what) {
    if (c.text.trim().isEmpty) return null;
    final v = _intOrNull(c.text);
    if (v == null) throw StockRuleException('$what must be a whole number.');
    return v;
  }

  int? _optPrice(TextEditingController c, String what) {
    if (c.text.trim().isEmpty) return null;
    final v = parseKes(c.text);
    if (v == null) {
      throw StockRuleException('$what is not a valid amount. Example: 12.50');
    }
    return v;
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final stock = ref.read(stockServiceProvider);
    try {
      final input = MedicineInput(
        name: _name.text,
        genericName: _generic.text,
        barcode: _barcode.text,
        baseUnitName: _unit.text,
        unitsPerStrip: _optInt(_perStrip, 'Units per strip'),
        unitsPerPack: _optInt(_perPack, 'Units per pack'),
        pricePerPackCents: _optPrice(_pricePack, 'The pack price'),
        pricePerStripCents: _optPrice(_priceStrip, 'The strip price'),
        pricePerUnitCents: _optPrice(_priceUnit, 'The single price'),
        lowStockThreshold: _optInt(_low, 'The low-stock level') ?? 0,
      );
      if (m == null) {
        await stock.createMedicine(input, userId: widget.userId);
      } else {
        await stock.updateMedicine(m!.id, input);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      final msg = userMessage(e);
      if (msg == null) rethrow;
      if (mounted) setState(() => _error = msg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? help,
    bool autofocus = false,
    List<TextInputFormatter>? formatters,
    String? prefix,
  }) => TextField(
    controller: c,
    autofocus: autofocus,
    inputFormatters: formatters,
    textInputAction: TextInputAction.next,
    decoration: InputDecoration(
      labelText: label,
      helperText: help,
      prefixText: prefix,
    ),
  );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final isNew = m == null;
    const gap = SizedBox(height: Space.lg);
    const hgap = SizedBox(width: Space.md);
    return SheetFrame(
      maxWidth: 600,
      title: isNew ? 'Add medicine' : 'Edit ${m!.name}',
      intro:
          'Prices are what the customer pays. Leave a price empty if you do not sell it that way.',
      actionLabel: isNew ? 'Add medicine' : 'Save changes',
      onAction: _save,
      busy: _busy,
      error: _error,
      children: [
        _field(
          _name,
          'Medicine name',
          autofocus: true,
          help: 'Include the strength, for example Paracetamol 500mg',
        ),
        gap,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: _field(_generic, 'Generic name (optional)')),
            hgap,
            Expanded(
              child: _field(
                _barcode,
                'Barcode (optional)',
                help: 'Scan it in this box',
              ),
            ),
          ],
        ),
        gap,
        Text('How it is counted and sold', style: t.titleMedium),
        const SizedBox(height: Space.sm),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _field(_unit, 'Smallest unit', help: 'tablet, ml, sachet'),
            ),
            hgap,
            Expanded(
              child: _field(
                _perStrip,
                'Units per strip',
                help: 'Empty if none',
                formatters: _digits,
              ),
            ),
            hgap,
            Expanded(
              child: _field(
                _perPack,
                'Units per pack',
                help: 'Empty if none',
                formatters: _digits,
              ),
            ),
          ],
        ),
        gap,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _field(
                _pricePack,
                'Price per pack',
                prefix: 'KES ',
                formatters: _money,
              ),
            ),
            hgap,
            Expanded(
              child: _field(
                _priceStrip,
                'Price per strip',
                prefix: 'KES ',
                formatters: _money,
              ),
            ),
            hgap,
            Expanded(
              child: _field(
                _priceUnit,
                'Price per single',
                prefix: 'KES ',
                formatters: _money,
              ),
            ),
          ],
        ),
        gap,
        _field(
          _low,
          'Low-stock level',
          help:
              'Warn when sellable stock falls to this many units or fewer. Empty means no warning.',
          formatters: _digits,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

/// Receive a delivery into a batch. Quantity and cost are entered the way the
/// delivery note states them (packs, strips or singles) and converted.
class ReceiveStockDialog extends ConsumerStatefulWidget {
  const ReceiveStockDialog({
    super.key,
    required this.medicines,
    this.initial,
    required this.userId,
  });
  final List<Medicine> medicines;
  final Medicine? initial;
  final int userId;

  @override
  ConsumerState<ReceiveStockDialog> createState() => _ReceiveStockDialogState();
}

class _ReceiveStockDialogState extends ConsumerState<ReceiveStockDialog> {
  Medicine? _med;
  PriceMode? _mode;
  final _batch = TextEditingController();
  final _expiry = TextEditingController();
  final _qty = TextEditingController();
  final _cost = TextEditingController();
  final _note = TextEditingController();
  bool _noExpiry = false;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _pick(widget.initial);
  }

  @override
  void dispose() {
    for (final c in [_batch, _expiry, _qty, _cost, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  void _pick(Medicine? m) {
    _med = m;
    final modes = m == null ? <PriceMode>[] : offeredModes(m);
    _mode = modes.isEmpty ? null : modes.first;
  }

  /// Everything derived from what is typed, or an error in words.
  ({int baseQty, int unitCost})? _parse() {
    final m = _med, mode = _mode;
    if (m == null || mode == null) return null;
    final qty = _intOrNull(_qty.text);
    final cost = parseKes(_cost.text);
    if (qty == null || qty <= 0 || cost == null) return null;
    final per = unitsIn(m, mode);
    return (baseQty: qty * per, unitCost: (cost / per).round());
  }

  Future<void> _save() async {
    final m = _med;
    if (m == null) {
      return setState(() => _error = 'Pick the medicine you are receiving.');
    }
    final expiry = _noExpiry ? null : parseExpiry(_expiry.text);
    if (!_noExpiry && expiry == null) {
      return setState(
        () =>
            _error = 'Enter the expiry as month and year, for example 12/2027.',
      );
    }
    final qty = _intOrNull(_qty.text);
    if (qty == null || qty <= 0) {
      return setState(() => _error = 'Enter how many you received.');
    }
    final cost = parseKes(_cost.text);
    if (cost == null) {
      return setState(
        () => _error = 'Enter what you paid. Example: 800 or 12.50',
      );
    }
    final p = _parse()!;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(stockServiceProvider)
          .receiveStock(
            medicineId: m.id,
            batchNumber: _batch.text,
            expiry: expiry,
            qtyBaseUnits: p.baseQty,
            costPerUnitCents: p.unitCost,
            supplierNote: _note.text,
            userId: widget.userId,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      final msg = userMessage(e);
      if (msg == null) rethrow;
      if (mounted) setState(() => _error = msg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final m = _med;
    final modes = m == null ? <PriceMode>[] : offeredModes(m);
    final p = _parse();
    const gap = SizedBox(height: Space.lg);
    return SheetFrame(
      maxWidth: 560,
      title: 'Receive stock',
      intro:
          'Enter the delivery as it appears on the pack and the delivery note.',
      actionLabel: 'Receive stock',
      onAction: _save,
      busy: _busy,
      error: _error,
      children: [
        DropdownMenu<Medicine>(
          initialSelection: widget.initial,
          enableFilter: true,
          requestFocusOnTap: true,
          expandedInsets: EdgeInsets.zero,
          label: const Text('Medicine'),
          dropdownMenuEntries: [
            for (final x in widget.medicines)
              DropdownMenuEntry(value: x, label: x.name),
          ],
          onSelected: (x) => setState(() => _pick(x)),
        ),
        gap,
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _batch,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Batch number'),
              ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: TextField(
                controller: _expiry,
                enabled: !_noExpiry,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Expiry (month/year)',
                  hintText: '12/2027',
                ),
              ),
            ),
          ],
        ),
        CheckboxListTile(
          value: _noExpiry,
          onChanged: (v) => setState(() => _noExpiry = v ?? false),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          dense: true,
          title: Text('This item has no expiry date', style: t.bodySmall),
        ),
        gap,
        if (m != null && modes.isEmpty)
          Text(
            'This medicine has no selling price set. Edit it first.',
            style: t.bodySmall,
          )
        else ...[
          if (modes.length > 1) ...[
            Text('Received as', style: t.labelMedium),
            const SizedBox(height: Space.sm),
            SegmentedButton<PriceMode>(
              showSelectedIcon: false,
              segments: [
                for (final x in modes)
                  ButtonSegment(
                    value: x,
                    label: Text(
                      x == PriceMode.unit
                          ? 'Single ${m!.baseUnitName}s'
                          : '${modeLabel(x)}s (${unitsIn(m!, x)} each)',
                    ),
                  ),
              ],
              selected: {_mode ?? modes.first},
              onSelectionChanged: (s) => setState(() => _mode = s.single),
            ),
            gap,
          ],
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _qty,
                  inputFormatters: _digits,
                  onChanged: (_) => setState(() {}),
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: m == null || _mode == null
                        ? 'Quantity'
                        : 'How many ${modeLabel(_mode!).toLowerCase()}s',
                  ),
                ),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: TextField(
                  controller: _cost,
                  inputFormatters: _money,
                  onChanged: (_) => setState(() {}),
                  textInputAction: TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: m == null || _mode == null
                        ? 'Cost'
                        : 'Cost per ${modeLabel(_mode!).toLowerCase()}',
                    prefixText: 'KES ',
                  ),
                ),
              ),
            ],
          ),
          if (p != null) ...[
            const SizedBox(height: Space.sm),
            Text(
              '= ${quantityText(p.baseQty, m!.baseUnitName)}, costing ${formatKes(p.unitCost)} each.',
              style: t.bodySmall,
            ),
          ],
        ],
        gap,
        TextField(
          controller: _note,
          decoration: const InputDecoration(
            labelText: 'Supplier or note (optional)',
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

/// Batches of one medicine, soonest expiry first. Owner can adjust.
class BatchesDialog extends ConsumerWidget {
  const BatchesDialog({
    super.key,
    required this.medicineId,
    required this.canAdjust,
    required this.userId,
  });
  final int medicineId;
  final bool canAdjust;
  final int userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final all = ref.watch(stockProvider).value ?? const [];
    final ms = all.where((x) => x.medicine.id == medicineId).firstOrNull;
    if (ms == null) return const SizedBox.shrink();
    final unit = ms.medicine.baseUnitName;
    return SheetFrame(
      maxWidth: 760,
      title: '${ms.medicine.name}: batches',
      intro: ms.batches.isEmpty
          ? 'Nothing has been received yet.'
          : 'Sales take from the batch that expires first. ${quantityText(ms.onHand, unit)} in total.',
      actionLabel: '',
      onAction: null,
      cancelLabel: 'Close',
      children: [
        for (final b in ms.batches)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Space.xs),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: Text(b.batch.batchNumber, style: t.titleMedium),
                ),
                Expanded(
                  flex: 3,
                  child: Wrap(
                    spacing: Space.sm,
                    runSpacing: Space.xs,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        b.batch.expiryDate == null
                            ? 'No expiry'
                            : formatExpiry(b.batch.expiryDate!),
                        style: t.bodyMedium,
                      ),
                      ExpiryChip(
                        state: expiryState(b.batch.expiryDate, ms.now),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    quantityText(b.onHand, unit),
                    style: t.bodyMedium!.copyWith(
                      color: b.onHand == 0 ? context.colors.textTertiary : null,
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Text(
                    b.batch.costPerUnitCents == null
                        ? 'Cost not recorded'
                        : '${formatKes(b.batch.costPerUnitCents!)} each',
                    style: t.bodySmall,
                  ),
                ),
                if (canAdjust)
                  TextButton(
                    onPressed: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (_) => AdjustStockDialog(
                          batch: b,
                          medicine: ms.medicine,
                          now: ms.now,
                          userId: userId,
                        ),
                      );
                      if (ok == true) ref.invalidate(stockProvider);
                    },
                    child: const Text('Adjust'),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------

enum _AdjustKind {
  writeOffExpired,
  writeOffDamaged,
  correctionAdd,
  correctionRemove,
}

/// Owner: write off or correct a batch. Always needs a reason in words.
class AdjustStockDialog extends ConsumerStatefulWidget {
  const AdjustStockDialog({
    super.key,
    required this.batch,
    required this.medicine,
    required this.now,
    required this.userId,
  });
  final BatchStock batch;
  final Medicine medicine;
  final DateTime now;
  final int userId;

  @override
  ConsumerState<AdjustStockDialog> createState() => _AdjustStockDialogState();
}

class _AdjustStockDialogState extends ConsumerState<AdjustStockDialog> {
  late _AdjustKind _kind =
      expiryState(widget.batch.batch.expiryDate, widget.now) ==
          ExpiryState.expired
      ? _AdjustKind.writeOffExpired
      : _AdjustKind.writeOffDamaged;
  final _qty = TextEditingController();
  final _note = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _qty.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final q = _intOrNull(_qty.text);
    if (q == null || q <= 0) {
      return setState(() => _error = 'Enter how many to change by.');
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(stockServiceProvider)
          .adjustStock(
            batchId: widget.batch.batch.id,
            qtyDelta: _kind == _AdjustKind.correctionAdd ? q : -q,
            reason: switch (_kind) {
              _AdjustKind.writeOffExpired => MovementReason.writeOffExpired,
              _AdjustKind.writeOffDamaged => MovementReason.writeOffDamaged,
              _ => MovementReason.adjustment,
            },
            note: _note.text,
            userId: widget.userId,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      final msg = userMessage(e);
      if (msg == null) rethrow;
      if (mounted) setState(() => _error = msg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final unit = widget.medicine.baseUnitName;
    final q = _intOrNull(_qty.text) ?? 0;
    final removes = _kind != _AdjustKind.correctionAdd;
    final after = widget.batch.onHand + (removes ? -q : q);
    final isWriteOff =
        _kind == _AdjustKind.writeOffExpired ||
        _kind == _AdjustKind.writeOffDamaged;
    return SheetFrame(
      title: 'Adjust batch ${widget.batch.batch.batchNumber}',
      intro:
          'Now ${quantityText(widget.batch.onHand, unit)}. This is recorded with your name and cannot be undone, '
          'only corrected with another entry.',
      actionLabel: isWriteOff ? 'Write off' : 'Save correction',
      destructive: isWriteOff,
      onAction: _save,
      busy: _busy,
      error: _error,
      children: [
        SegmentedButton<_AdjustKind>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: _AdjustKind.writeOffExpired,
              label: Text('Expired'),
            ),
            ButtonSegment(
              value: _AdjustKind.writeOffDamaged,
              label: Text('Damaged'),
            ),
            ButtonSegment(
              value: _AdjustKind.correctionRemove,
              label: Text('Count: less'),
            ),
            ButtonSegment(
              value: _AdjustKind.correctionAdd,
              label: Text('Count: more'),
            ),
          ],
          selected: {_kind},
          onSelectionChanged: (s) => setState(() => _kind = s.single),
        ),
        const SizedBox(height: Space.lg),
        TextField(
          controller: _qty,
          autofocus: true,
          inputFormatters: _digits,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: 'How many ${widget.medicine.baseUnitName}s',
            helperText: q > 0 && after >= 0
                ? 'Leaves ${quantityText(after, unit)}'
                : null,
          ),
        ),
        const SizedBox(height: Space.lg),
        TextField(
          controller: _note,
          onSubmitted: (_) => _save(),
          decoration: const InputDecoration(
            labelText: 'Reason',
            hintText: 'For example: pack damaged by water',
          ),
        ),
      ],
    );
  }
}
