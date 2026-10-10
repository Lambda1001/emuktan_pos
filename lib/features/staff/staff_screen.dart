import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../data/database.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/error_line.dart';
import '../shell/destinations.dart';
import 'staff_dialogs.dart';

final staffProvider = FutureProvider.autoDispose<List<User>>(
  (ref) => ref.watch(authServiceProvider).allUsers(),
);

/// Owner-only: add, edit, reset PIN, deactivate and reactivate staff.
class StaffScreen extends ConsumerWidget {
  const StaffScreen({super.key, required this.me});
  final User me;

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// If the owner edited their own account, the open session must follow.
  Future<void> _refreshSelf(WidgetRef ref) async {
    final fresh = (await ref.read(authServiceProvider).allUsers())
        .where((u) => u.id == me.id)
        .firstOrNull;
    if (fresh != null &&
        (fresh.role != me.role || fresh.displayName != me.displayName)) {
      ref.read(sessionProvider.notifier).signIn(fresh);
    }
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<bool?> dialog,
    String doneMessage, {
    bool touchesSelf = false,
  }) async {
    final ok = await dialog;
    if (ok != true) return;
    ref.invalidate(staffProvider);
    if (touchesSelf) await _refreshSelf(ref);
    if (context.mounted) _toast(context, doneMessage);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final staff = ref.watch(staffProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'People who can sign in. Deactivate someone who has left; '
                'their history is kept.',
                style: t.bodySmall,
              ),
            ),
            FilledButton.icon(
              onPressed: () => _run(
                context,
                ref,
                showDialog<bool>(
                  context: context,
                  builder: (_) => const StaffFormDialog(),
                ),
                'Staff member added.',
              ),
              icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
              label: const Text('Add staff'),
            ),
          ],
        ),
        const SizedBox(height: Space.lg),
        Expanded(
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: staff.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(Space.xl),
                child: ErrorLine('Could not load staff. $e'),
              ),
              data: (users) => Column(
                children: [
                  const _HeaderRow(),
                  const Divider(),
                  Expanded(
                    child: ListView.separated(
                      itemCount: users.length,
                      separatorBuilder: (_, _) => const Divider(),
                      itemBuilder: (context, i) => _StaffRow(
                        user: users[i],
                        isMe: users[i].id == me.id,
                        onEdit: () => _run(
                          context,
                          ref,
                          showDialog<bool>(
                            context: context,
                            builder: (_) => StaffFormDialog(existing: users[i]),
                          ),
                          'Changes saved.',
                          touchesSelf: users[i].id == me.id,
                        ),
                        onResetPin: () => _run(
                          context,
                          ref,
                          showDialog<bool>(
                            context: context,
                            builder: (_) => ResetPinDialog(user: users[i]),
                          ),
                          'PIN reset for ${users[i].displayName}.',
                        ),
                        onDeactivate: () => _run(
                          context,
                          ref,
                          showDialog<bool>(
                            context: context,
                            builder: (_) => DeactivateDialog(
                              user: users[i],
                              actingUserId: me.id,
                            ),
                          ),
                          '${users[i].displayName} deactivated.',
                        ),
                        onReactivate: () async {
                          await ref
                              .read(authServiceProvider)
                              .setActive(
                                users[i].id,
                                true,
                                actingUserId: me.id,
                              );
                          ref.invalidate(staffProvider);
                          if (context.mounted) {
                            _toast(
                              context,
                              '${users[i].displayName} can sign in again.',
                            );
                          }
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

const _rowPad = EdgeInsets.symmetric(horizontal: Space.lg);

class _HeaderRow extends StatelessWidget {
  const _HeaderRow();

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).textTheme.labelSmall!;
    return Padding(
      padding: _rowPad,
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            Expanded(flex: 4, child: Text('Name', style: s)),
            Expanded(flex: 3, child: Text('Role', style: s)),
            Expanded(flex: 2, child: Text('Status', style: s)),
            const SizedBox(width: 420),
          ],
        ),
      ),
    );
  }
}

class _StaffRow extends StatelessWidget {
  const _StaffRow({
    required this.user,
    required this.isMe,
    required this.onEdit,
    required this.onResetPin,
    required this.onDeactivate,
    required this.onReactivate,
  });
  final User user;
  final bool isMe;
  final VoidCallback onEdit, onResetPin, onDeactivate, onReactivate;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = context.colors;
    return Padding(
      padding: _rowPad,
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            Expanded(
              flex: 4,
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      user.displayName,
                      overflow: TextOverflow.ellipsis,
                      style: t.titleMedium!.copyWith(
                        color: user.active ? c.text : c.textTertiary,
                      ),
                    ),
                  ),
                  if (isMe) Text('  (you)', style: t.bodySmall),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(roleLabel(user.role), style: t.bodyMedium),
            ),
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _StatusChip(active: user.active),
              ),
            ),
            SizedBox(
              width: 420,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: onEdit, child: const Text('Edit')),
                  TextButton(
                    onPressed: onResetPin,
                    child: const Text('Reset PIN'),
                  ),
                  if (user.active)
                    TextButton(
                      onPressed: isMe ? null : onDeactivate,
                      style: TextButton.styleFrom(foregroundColor: c.critical),
                      child: const Text('Deactivate'),
                    )
                  else
                    TextButton(
                      onPressed: onReactivate,
                      child: const Text('Reactivate'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fg = active ? c.success : c.textSecondary;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: active ? c.successSoft : c.separator.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active ? Icons.check_circle_outline : Icons.block,
              size: 14,
              color: fg,
            ),
            const SizedBox(width: Space.xs),
            Text(
              active ? 'Active' : 'Inactive',
              style: Theme.of(
                context,
              ).textTheme.labelSmall!.copyWith(color: fg),
            ),
          ],
        ),
      ),
    );
  }
}
