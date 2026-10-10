import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../config/app_config.dart';
import '../../data/auth_service.dart';
import '../../data/database.dart';
import '../../ui/theme/app_tokens.dart';
import '../shell/destinations.dart';
import 'auth_scaffold.dart';

/// Choose your name, then enter your PIN.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  late final Future<List<User>> _users = ref
      .read(authServiceProvider)
      .activeUsers();
  final _pin = TextEditingController();
  User? _selected;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  void _select(User? user) {
    setState(() {
      _selected = user;
      _error = null;
      _pin.clear();
    });
  }

  Future<void> _submit(User user) async {
    if (_busy || _pin.text.isEmpty) return;
    setState(() => _busy = true);
    final auth = ref.read(authServiceProvider);
    try {
      final ok = await auth.signIn(user.id, _pin.text);
      if (ok != null) {
        ref.read(sessionProvider.notifier).signIn(ok);
        return;
      }
      _pin.clear();
      final locked = auth.lockedSeconds(user.id);
      if (mounted) {
        setState(
          () => _error = locked > 0
              ? PinLockedException(locked).toString()
              : 'That PIN is not right. Try again, or ask the owner to reset it.',
        );
      }
    } on PinLockedException catch (e) {
      _pin.clear();
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return AuthScaffold(
      child: FutureBuilder<List<User>>(
        future: _users,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final users = snap.data!;
          // A shop with one account goes straight to the PIN.
          final selected =
              _selected ?? (users.length == 1 ? users.single : null);
          if (selected == null) return _pickUser(t, users);
          return _pinEntry(t, selected, canGoBack: users.length > 1);
        },
      ),
    );
  }

  Widget _pickUser(TextTheme t, List<User> users) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Who is signing in?', style: t.titleLarge),
        const SizedBox(height: Space.lg),
        for (final u in users)
          Padding(
            padding: const EdgeInsets.only(bottom: Space.sm),
            child: OutlinedButton(
              onPressed: () => _select(u),
              style: OutlinedButton.styleFrom(
                alignment: Alignment.centerLeft,
                minimumSize: const Size.fromHeight(Hit.counter),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: c.accentSoft,
                    child: Text(
                      u.displayName.characters.first.toUpperCase(),
                      style: t.labelLarge!.copyWith(color: c.accent),
                    ),
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(child: Text(u.displayName, style: t.titleMedium)),
                  Text(roleLabel(u.role), style: t.bodySmall),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _pinEntry(TextTheme t, User user, {required bool canGoBack}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Hello, ${user.displayName}', style: t.titleLarge),
        const SizedBox(height: Space.xs),
        Text('Enter your PIN to continue.', style: t.bodySmall),
        const SizedBox(height: Space.lg),
        TextField(
          controller: _pin,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(AppConfig.pinMaxLength),
          ],
          onSubmitted: (_) => _submit(user),
          decoration: const InputDecoration(labelText: 'PIN'),
        ),
        if (_error != null) ...[
          const SizedBox(height: Space.md),
          ErrorLine(_error!),
        ],
        const SizedBox(height: Space.xl),
        Row(
          children: [
            if (canGoBack) ...[
              OutlinedButton(
                onPressed: () => _select(null),
                child: const Text('Back'),
              ),
              const SizedBox(width: Space.md),
            ],
            Expanded(
              child: FilledButton(
                onPressed: _busy ? null : () => _submit(user),
                child: const Text('Sign in'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
