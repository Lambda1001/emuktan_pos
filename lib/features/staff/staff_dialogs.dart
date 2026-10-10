import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../config/app_config.dart';
import '../../data/database.dart';
import '../../data/tables.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/sheet_frame.dart';
import '../shell/destinations.dart';

Widget _pinField(
  TextEditingController c,
  String label, {
  String? help,
  bool autofocus = false,
  ValueChanged<String>? onSubmitted,
  TextInputAction action = TextInputAction.next,
}) => TextField(
  controller: c,
  autofocus: autofocus,
  obscureText: true,
  keyboardType: TextInputType.number,
  textInputAction: action,
  onSubmitted: onSubmitted,
  inputFormatters: [
    FilteringTextInputFormatter.digitsOnly,
    LengthLimitingTextInputFormatter(AppConfig.pinMaxLength),
  ],
  decoration: InputDecoration(
    labelText: label,
    helperText:
        help ?? '${AppConfig.pinMinLength} to ${AppConfig.pinMaxLength} digits',
  ),
);

/// Add a staff member ([existing] null) or edit name and role.
class StaffFormDialog extends ConsumerStatefulWidget {
  const StaffFormDialog({super.key, this.existing});
  final User? existing;

  @override
  ConsumerState<StaffFormDialog> createState() => _StaffFormDialogState();
}

class _StaffFormDialogState extends ConsumerState<StaffFormDialog> {
  late final _name = TextEditingController(text: widget.existing?.displayName);
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  late Role _role = widget.existing?.role ?? Role.cashier;
  String? _error;
  bool _busy = false;

  bool get _isNew => widget.existing == null;

  @override
  void dispose() {
    _name.dispose();
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_isNew && _pin.text != _confirm.text) {
      setState(() => _error = 'The two PINs do not match. Type them again.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final auth = ref.read(authServiceProvider);
    try {
      if (_isNew) {
        await auth.createUser(
          displayName: _name.text,
          role: _role,
          pin: _pin.text,
        );
      } else {
        await auth.updateUser(
          widget.existing!.id,
          displayName: _name.text,
          role: _role,
        );
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

  @override
  Widget build(BuildContext context) {
    return SheetFrame(
      title: _isNew ? 'Add staff' : 'Edit ${widget.existing!.displayName}',
      intro: _isNew
          ? 'They will sign in with their name and this PIN. They can change the PIN later.'
          : 'Change the name or the role. The PIN stays the same.',
      actionLabel: _isNew ? 'Add staff' : 'Save changes',
      onAction: _save,
      error: _error,
      busy: _busy,
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Full name'),
        ),
        const SizedBox(height: Space.lg),
        Text('Role', style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: Space.sm),
        SegmentedButton<Role>(
          showSelectedIcon: false,
          segments: [
            for (final r in [Role.cashier, Role.clinician, Role.owner])
              ButtonSegment(value: r, label: Text(roleLabel(r))),
          ],
          selected: {_role},
          onSelectionChanged: (s) => setState(() => _role = s.single),
        ),
        const SizedBox(height: Space.sm),
        Text(_roleHelp(_role), style: Theme.of(context).textTheme.bodySmall),
        if (_isNew) ...[
          const SizedBox(height: Space.lg),
          _pinField(_pin, 'PIN'),
          const SizedBox(height: Space.lg),
          _pinField(
            _confirm,
            'Type the PIN again',
            help: ' ',
            action: TextInputAction.done,
            onSubmitted: (_) => _save(),
          ),
        ],
      ],
    );
  }
}

String _roleHelp(Role r) => switch (r) {
  Role.cashier => 'Sells, registers patients, receives stock, clocks in.',
  Role.clinician =>
    'Everything a cashier does, with full patient records, and can approve discounts.',
  Role.owner =>
    'Everything, including reports, staff and settings, and can approve discounts.',
};

/// Owner sets a new PIN for someone else.
class ResetPinDialog extends ConsumerStatefulWidget {
  const ResetPinDialog({super.key, required this.user});
  final User user;

  @override
  ConsumerState<ResetPinDialog> createState() => _ResetPinDialogState();
}

class _ResetPinDialogState extends ConsumerState<ResetPinDialog> {
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_pin.text != _confirm.text) {
      setState(() => _error = 'The two PINs do not match. Type them again.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(authServiceProvider).resetPin(widget.user.id, _pin.text);
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
  Widget build(BuildContext context) => SheetFrame(
    title: 'Reset PIN for ${widget.user.displayName}',
    intro:
        'Their old PIN stops working straight away. Tell them the new one in person.',
    actionLabel: 'Reset PIN',
    onAction: _save,
    error: _error,
    busy: _busy,
    children: [
      _pinField(_pin, 'New PIN', autofocus: true),
      const SizedBox(height: Space.lg),
      _pinField(
        _confirm,
        'Type the new PIN again',
        help: ' ',
        action: TextInputAction.done,
        onSubmitted: (_) => _save(),
      ),
    ],
  );
}

/// Anyone changes their own PIN.
class ChangeOwnPinDialog extends ConsumerStatefulWidget {
  const ChangeOwnPinDialog({super.key, required this.user});
  final User user;

  @override
  ConsumerState<ChangeOwnPinDialog> createState() => _ChangeOwnPinDialogState();
}

class _ChangeOwnPinDialogState extends ConsumerState<ChangeOwnPinDialog> {
  final _current = TextEditingController();
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _current.dispose();
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_pin.text != _confirm.text) {
      setState(
        () => _error = 'The two new PINs do not match. Type them again.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authServiceProvider)
          .changeOwnPin(
            widget.user.id,
            currentPin: _current.text,
            newPin: _pin.text,
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
  Widget build(BuildContext context) => SheetFrame(
    title: 'Change your PIN',
    intro: 'Enter your current PIN, then choose a new one.',
    actionLabel: 'Change PIN',
    onAction: _save,
    error: _error,
    busy: _busy,
    children: [
      _pinField(_current, 'Current PIN', autofocus: true, help: ' '),
      const SizedBox(height: Space.lg),
      _pinField(_pin, 'New PIN'),
      const SizedBox(height: Space.lg),
      _pinField(
        _confirm,
        'Type the new PIN again',
        help: ' ',
        action: TextInputAction.done,
        onSubmitted: (_) => _save(),
      ),
    ],
  );
}

/// Confirmation for turning an account off. States the consequence.
class DeactivateDialog extends ConsumerStatefulWidget {
  const DeactivateDialog({
    super.key,
    required this.user,
    required this.actingUserId,
  });
  final User user;
  final int actingUserId;

  @override
  ConsumerState<DeactivateDialog> createState() => _DeactivateDialogState();
}

class _DeactivateDialogState extends ConsumerState<DeactivateDialog> {
  String? _error;
  bool _busy = false;

  Future<void> _go() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(authServiceProvider)
          .setActive(widget.user.id, false, actingUserId: widget.actingUserId);
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
  Widget build(BuildContext context) => SheetFrame(
    title: 'Deactivate ${widget.user.displayName}?',
    intro:
        'They will no longer be able to sign in. Their past sales and records '
        'are kept. You can turn the account back on at any time.',
    actionLabel: 'Deactivate',
    destructive: true,
    onAction: _go,
    error: _error,
    busy: _busy,
    children: const [],
  );
}
