import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../core/format.dart';
import '../../data/database.dart';
import '../../data/sales_service.dart';
import '../../data/tables.dart';
import '../../domain/cart.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/error_line.dart';
import 'sell_dialogs.dart' show Discount;

/// Notes the customer is likely to hand over (Kenyan shillings), in KES.
const _quickNotes = [50, 100, 200, 500, 1000];

/// The payment panel: what is due, how it is paid, and a number pad for the
/// cash received. Completes the sale itself so a refusal (for example, stock
/// that changed) is shown here, with the sale still intact behind it.
///
/// Works from the keyboard as well: digits and the decimal point type the
/// amount, Backspace deletes, Enter completes, Esc goes back.
class PayDialog extends ConsumerStatefulWidget {
  const PayDialog({
    super.key,
    required this.me,
    required this.lines,
    required this.subtotalCents,
    required this.discount,
    required this.totalCents,
  });
  final User me;
  final List<CartLine> lines;
  final int subtotalCents, totalCents;
  final Discount? discount;

  @override
  ConsumerState<PayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends ConsumerState<PayDialog> {
  final _keys = FocusNode(debugLabel: 'pay-keys');
  final _mpesa = TextEditingController();
  PaymentMethod _method = PaymentMethod.cash;
  String _cash = '';
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _keys.dispose();
    _mpesa.dispose();
    super.dispose();
  }

  int get _total => widget.totalCents;

  /// Cents typed so far, or null if nothing valid is typed yet.
  int? get _cashCents {
    if (_cash.isEmpty || _cash == '.') return null;
    return parseKes(
      _cash.endsWith('.') ? _cash.substring(0, _cash.length - 1) : _cash,
    );
  }

  bool get _canComplete => _method == PaymentMethod.cash
      ? (_cashCents ?? -1) >= _total
      : _mpesa.text.trim().length >= 8;

  void _press(String k) {
    if (_busy) return;
    setState(() {
      _error = null;
      if (k == '.') {
        if (_cash.contains('.')) return;
        _cash = _cash.isEmpty ? '0.' : '$_cash.';
        return;
      }
      final dot = _cash.indexOf('.');
      if (dot >= 0 && _cash.length - dot > 2) return; // two decimals at most
      if (dot < 0 && _cash.length >= 9) return;
      _cash = _cash == '0' ? k : '$_cash$k';
    });
  }

  void _backspace() => setState(() {
    _error = null;
    if (_cash.isNotEmpty) _cash = _cash.substring(0, _cash.length - 1);
  });

  void _clear() => setState(() {
    _error = null;
    _cash = '';
  });

  void _setCents(int cents) => setState(() {
    _error = null;
    _cash = cents % 100 == 0
        ? '${cents ~/ 100}'
        : '${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')}';
  });

  void _chooseMethod(PaymentMethod m) {
    setState(() {
      _method = m;
      _error = null;
    });
    if (m == PaymentMethod.cash) _keys.requestFocus();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    if (_method != PaymentMethod.cash) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_canComplete && !_busy) _complete();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }
    final ch = event.character;
    if (ch != null && RegExp(r'^[0-9.]$').hasMatch(ch)) {
      _press(ch);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _complete() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final receipt = await ref
          .read(salesServiceProvider)
          .completeSale(
            lines: widget.lines,
            cashierId: widget.me.id,
            discountCents: widget.discount?.cents ?? 0,
            discountApprovedBy: widget.discount?.approverId,
            method: _method,
            cashTenderedCents: _method == PaymentMethod.cash
                ? _cashCents
                : null,
            mpesaCode: _mpesa.text,
          );
      if (mounted) Navigator.of(context).pop(receipt);
    } on SaleRuleException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = context.colors;
    final cash = _cashCents;
    final change = (cash != null && cash >= _total) ? cash - _total : null;
    final short = (cash != null && cash < _total) ? _total - cash : null;

    return Focus(
      focusNode: _keys,
      autofocus: true,
      onKeyEvent: _onKey,
      child: Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: Padding(
            padding: const EdgeInsets.all(Space.xl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('Payment', style: t.titleLarge),
                const SizedBox(height: Space.lg),
                SizedBox(
                  height: 440,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // ---- left: what is due and how --------------------
                      Expanded(
                        flex: 5,
                        child: SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Total to pay', style: t.bodySmall),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  formatKes(_total, alwaysCents: true),
                                  style: t.displaySmall!.copyWith(fontSize: 52),
                                ),
                              ),
                              if (widget.discount != null)
                                Text(
                                  'After a discount of ${formatKes(widget.discount!.cents)}, '
                                  'approved by ${widget.discount!.approverName}.',
                                  style: t.bodySmall,
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
                                onSelectionChanged: (s) =>
                                    _chooseMethod(s.single),
                              ),
                              const SizedBox(height: Space.xl),
                              if (_method == PaymentMethod.cash) ...[
                                Text('Cash received', style: t.bodySmall),
                                Text(
                                  _cash.isEmpty
                                      ? 'KES 0'
                                      : 'KES ${_cash.contains('.') ? _cash : _group(_cash)}',
                                  key: const Key('cash-received'),
                                  style: t.displaySmall,
                                ),
                                const SizedBox(height: Space.md),
                                if (change != null)
                                  _Result(
                                    icon: Icons.check_circle_outline,
                                    color: c.success,
                                    label: 'Change due',
                                    value: formatKes(change, alwaysCents: true),
                                  )
                                else if (short != null)
                                  _Result(
                                    icon: Icons.error_outline,
                                    color: c.critical,
                                    label: 'Still to pay',
                                    value: formatKes(short, alwaysCents: true),
                                  )
                                else
                                  Text(
                                    'Type the amount, or tap Exact or a note.',
                                    style: t.bodySmall,
                                  ),
                              ] else ...[
                                TextField(
                                  controller: _mpesa,
                                  autofocus: true,
                                  onChanged: (_) =>
                                      setState(() => _error = null),
                                  onSubmitted: (_) {
                                    if (_canComplete && !_busy) _complete();
                                  },
                                  textCapitalization:
                                      TextCapitalization.characters,
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
                                const SizedBox(height: Space.md),
                                Text(
                                  'Check the M-Pesa message shows '
                                  '${formatKes(_total, alwaysCents: true)}, then type its code.',
                                  style: t.bodySmall,
                                ),
                              ],
                              if (_error != null) ...[
                                const SizedBox(height: Space.md),
                                ErrorLine(_error!),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const VerticalDivider(width: Space.xxl),

                      // ---- right: number pad ----------------------------
                      Expanded(
                        flex: 4,
                        child: _method == PaymentMethod.cash
                            ? ExcludeFocus(child: _pad())
                            : Center(
                                child: Text(
                                  'Payment by M-Pesa needs no cash entry.',
                                  style: t.bodySmall,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Space.lg),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: Space.md,
                  runSpacing: Space.sm,
                  children: [
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.of(context).pop(),
                      child: const Text('Back to sale'),
                    ),
                    FilledButton(
                      onPressed: (_canComplete && !_busy) ? _complete : null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(160, Hit.counter),
                      ),
                      child: Text(_busy ? 'Saving…' : 'Complete sale'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// "1500" -> "1,500" for the big display.
  String _group(String digits) {
    final out = StringBuffer();
    for (var i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
      out.write(digits[i]);
    }
    return out.toString();
  }

  Widget _pad() {
    Widget key(String label, VoidCallback onTap, {String? tooltip}) => Expanded(
      child: Padding(
        padding: const EdgeInsets.all(Space.xs),
        child: Tooltip(
          message: tooltip ?? '',
          child: FilledButton.tonal(
            onPressed: _busy ? null : onTap,
            style: FilledButton.styleFrom(
              minimumSize: const Size(0, 60),
              textStyle: Theme.of(context).textTheme.titleLarge,
            ),
            child: Text(label),
          ),
        ),
      ),
    );

    Widget row(List<Widget> keys) => Expanded(child: Row(children: keys));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: [
            OutlinedButton(
              onPressed: _busy ? null : () => _setCents(_total),
              child: const Text('Exact'),
            ),
            for (final n in _quickNotes)
              OutlinedButton(
                onPressed: _busy ? null : () => _setCents(n * 100),
                child: Text(formatKes(n * 100)),
              ),
          ],
        ),
        const SizedBox(height: Space.md),
        row([
          key('7', () => _press('7')),
          key('8', () => _press('8')),
          key('9', () => _press('9')),
        ]),
        row([
          key('4', () => _press('4')),
          key('5', () => _press('5')),
          key('6', () => _press('6')),
        ]),
        row([
          key('1', () => _press('1')),
          key('2', () => _press('2')),
          key('3', () => _press('3')),
        ]),
        row([
          key('.', () => _press('.')),
          key('0', () => _press('0')),
          key('⌫', _backspace, tooltip: 'Delete the last digit'),
        ]),
        Row(
          children: [
            Expanded(
              child: TextButton(
                onPressed: _busy ? null : _clear,
                child: const Text('Clear'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Result extends StatelessWidget {
  const _Result({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final Color color;
  final String label, value;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Row(
      children: [
        Icon(icon, color: color),
        const SizedBox(width: Space.sm),
        Text(label, style: t.titleMedium),
        const SizedBox(width: Space.md),
        Flexible(
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: t.titleLarge!.copyWith(color: color),
          ),
        ),
      ],
    );
  }
}
