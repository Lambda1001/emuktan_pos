import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../config/app_config.dart';
import '../../data/auth_service.dart';
import '../../data/tables.dart';
import '../../ui/theme/app_tokens.dart';
import 'auth_scaffold.dart';

/// First run only: create the owner account.
class SetupOwnerScreen extends ConsumerStatefulWidget {
  const SetupOwnerScreen({super.key});

  @override
  ConsumerState<SetupOwnerScreen> createState() => _SetupOwnerScreenState();
}

class _SetupOwnerScreenState extends ConsumerState<SetupOwnerScreen> {
  final _name = TextEditingController();
  final _pin = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _pin.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (_pin.text != _confirm.text) {
      setState(() => _error = 'The two PINs do not match. Type them again.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final user = await ref
          .read(authServiceProvider)
          .createUser(
            displayName: _name.text,
            role: Role.owner,
            pin: _pin.text,
          );
      ref.read(sessionProvider.notifier).signIn(user);
    } on PinPolicyException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final pinFormatters = [
      FilteringTextInputFormatter.digitsOnly,
      LengthLimitingTextInputFormatter(AppConfig.pinMaxLength),
    ];
    return AuthScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Set up the owner account', style: t.titleLarge),
          const SizedBox(height: Space.sm),
          Text(
            'You will use this PIN to sign in and to manage staff. '
            'You can add other staff after this.',
            style: t.bodySmall,
          ),
          const SizedBox(height: Space.xl),
          TextField(
            controller: _name,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(labelText: 'Your full name'),
          ),
          const SizedBox(height: Space.lg),
          TextField(
            controller: _pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: pinFormatters,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'PIN',
              helperText:
                  '${AppConfig.pinMinLength} to ${AppConfig.pinMaxLength} digits',
            ),
          ),
          const SizedBox(height: Space.lg),
          TextField(
            controller: _confirm,
            obscureText: true,
            keyboardType: TextInputType.number,
            inputFormatters: pinFormatters,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(labelText: 'Type the PIN again'),
          ),
          if (_error != null) ...[
            const SizedBox(height: Space.md),
            ErrorLine(_error!),
          ],
          const SizedBox(height: Space.xl),
          FilledButton(
            onPressed: _busy ? null : _submit,
            child: const Text('Create owner account'),
          ),
        ],
      ),
    );
  }
}
