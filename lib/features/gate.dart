import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app_state.dart';
import 'auth/setup_owner_screen.dart';
import 'auth/sign_in_screen.dart';
import 'shell/app_shell.dart';

/// Decides what to show: owner setup, sign-in, or the app.
class Gate extends ConsumerWidget {
  const Gate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionProvider);
    if (user != null) {
      return AppShell(
        key: ValueKey('${user.id}-${user.role.name}'),
        user: user,
      );
    }

    final hasUsers = ref.watch(hasUsersProvider);
    return hasUsers.when(
      data: (yes) => yes ? const SignInScreen() : const SetupOwnerScreen(),
      error: (e, _) => Scaffold(body: Center(child: SelectableText('$e'))),
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
    );
  }
}
