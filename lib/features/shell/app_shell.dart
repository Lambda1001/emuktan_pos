import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../config/app_config.dart';
import '../../data/database.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/brand_mark.dart';
import '../sell/sell_screen.dart';
import '../staff/staff_dialogs.dart';
import '../staff/staff_screen.dart';
import '../stock/stock_screen.dart';
import 'destinations.dart';

/// Sidebar, content area and status bar (DESIGN.md sections 3 and 4).
/// Locks back to sign-in after [AppConfig.inactivityLock] without input.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key, required this.user});
  final User user;

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  late final List<Destination> _destinations = destinationsFor(
    widget.user.role,
  );
  late Destination _current = _destinations.first;
  Timer? _idle;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
    _resetIdle();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _idle?.cancel();
    super.dispose();
  }

  bool _onKey(KeyEvent _) {
    _resetIdle();
    return false;
  }

  void _resetIdle() {
    _idle?.cancel();
    _idle = Timer(AppConfig.inactivityLock, _lock);
  }

  void _lock() => ref.read(sessionProvider.notifier).signOut();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _resetIdle(),
      onPointerMove: (_) => _resetIdle(),
      onPointerSignal: (_) => _resetIdle(),
      child: Scaffold(
        body: Column(
          children: [
            Expanded(
              child: Row(
                children: [
                  _Sidebar(
                    destinations: _destinations,
                    current: _current,
                    onSelect: (d) => setState(() => _current = d),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(Space.xl),
                      child: _Page(destination: _current, user: widget.user),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: Space.lg),
              decoration: BoxDecoration(
                color: c.sidebar,
                border: Border(top: BorderSide(color: c.separator)),
              ),
              child: _StatusBar(user: widget.user, onSwitch: _lock),
            ),
          ],
        ),
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.destinations,
    required this.current,
    required this.onSelect,
  });
  final List<Destination> destinations;
  final Destination current;
  final ValueChanged<Destination> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: 208,
      color: c.sidebar,
      padding: const EdgeInsets.all(Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(
              Space.sm,
              Space.sm,
              Space.sm,
              Space.xl,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: BrandMark(height: 32),
            ),
          ),
          for (final d in destinations)
            _NavItem(
              destination: d,
              selected: d == current,
              onTap: () => onSelect(d),
            ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });
  final Destination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.xs),
      child: Material(
        color: selected ? c.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(Radii.control),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.control),
          onTap: onTap,
          focusColor: c.accent.withValues(alpha: 0.16),
          hoverColor: c.separator.withValues(alpha: 0.5),
          child: SizedBox(
            height: Hit.standard,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.md),
              child: Row(
                children: [
                  Icon(
                    selected ? destination.selectedIcon : destination.icon,
                    size: 20,
                    color: selected ? c.accent : c.textSecondary,
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: Text(
                      destination.label,
                      overflow: TextOverflow.ellipsis,
                      style: t.labelLarge!.copyWith(
                        color: selected ? c.accent : c.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.destination, required this.user});
  final Destination destination;
  final User user;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(destination.label, style: t.titleLarge),
        const SizedBox(height: Space.lg),
        Expanded(
          child: destination == Destination.settings
              ? StaffScreen(me: user)
              : destination == Destination.sell
              ? SellScreen(me: user)
              : destination == Destination.stock
              ? StockScreen(me: user)
              : Card(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(destination.icon, size: 40, color: c.textTertiary),
                        const SizedBox(height: Space.md),
                        Text(destination.comingSoon, style: t.bodyMedium),
                        const SizedBox(height: Space.xs),
                        Text(
                          'This screen is not built yet.',
                          style: t.bodySmall,
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

class _StatusBar extends StatelessWidget {
  const _StatusBar({required this.user, required this.onSwitch});
  final User user;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final style = Theme.of(context).textTheme.labelSmall!;
    return Row(
      children: [
        Icon(Icons.cloud_off_outlined, size: 14, color: c.textSecondary),
        const SizedBox(width: Space.xs),
        Text('Working offline', style: style),
        const Spacer(),
        Icon(Icons.person_outline, size: 14, color: c.textSecondary),
        const SizedBox(width: Space.xs),
        Text('${user.displayName} · ${roleLabel(user.role)}', style: style),
        const SizedBox(width: Space.md),
        TextButton(
          onPressed: () =>
              showDialog<bool>(
                context: context,
                builder: (_) => ChangeOwnPinDialog(user: user),
              ).then((ok) {
                if (ok == true && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Your PIN has been changed.')),
                  );
                }
              }),
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 28),
            padding: const EdgeInsets.symmetric(horizontal: Space.sm),
            textStyle: style,
          ),
          child: const Text('Change PIN'),
        ),
        TextButton(
          onPressed: onSwitch,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 28),
            padding: const EdgeInsets.symmetric(horizontal: Space.sm),
            textStyle: style,
          ),
          child: const Text('Switch user'),
        ),
      ],
    );
  }
}
