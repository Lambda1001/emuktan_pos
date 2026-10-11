import 'package:flutter/material.dart';

import '../../data/database.dart';
import '../../ui/theme/app_tokens.dart';
import '../staff/staff_screen.dart';
import 'backup_panel.dart';

/// Owner-only: staff and backups.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.me});
  final User me;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

enum _Section { staff, backup }

class _SettingsScreenState extends State<SettingsScreen> {
  _Section _section = _Section.staff;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<_Section>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: _Section.staff, label: Text('Staff')),
            ButtonSegment(value: _Section.backup, label: Text('Backup')),
          ],
          selected: {_section},
          onSelectionChanged: (s) => setState(() => _section = s.single),
        ),
        const SizedBox(height: Space.lg),
        Expanded(
          child: switch (_section) {
            _Section.staff => StaffScreen(me: widget.me),
            _Section.backup => const BackupPanel(),
          },
        ),
      ],
    );
  }
}
