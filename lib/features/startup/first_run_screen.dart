import 'package:flutter/material.dart';

import '../../data/backup_service.dart';
import '../../ui/theme/app_tokens.dart';
import '../auth/auth_scaffold.dart';

/// Shown only on a PC that has no data yet. Either start a new shop, or bring
/// an existing shop back from a backup using the printed recovery key.
class FirstRunScreen extends StatefulWidget {
  const FirstRunScreen({
    super.key,
    required this.onNewShop,
    required this.onRestore,
  });
  final VoidCallback onNewShop;

  /// Throws [BackupException] with a plain message if it cannot restore.
  final Future<void> Function(String backupPath, String recoveryKey) onRestore;

  @override
  State<FirstRunScreen> createState() => _FirstRunScreenState();
}

class _FirstRunScreenState extends State<FirstRunScreen> {
  bool _restoring = false;
  final _path = TextEditingController();
  final _key = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _path.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    if (_path.text.trim().isEmpty) {
      setState(() => _error = 'Type the path of the backup file.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onRestore(_path.text.replaceAll('"', ''), _key.text);
    } on BackupException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    if (!_restoring) {
      return AuthScaffold(
        width: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Welcome', style: t.titleLarge),
            const SizedBox(height: Space.sm),
            Text('This computer has no shop data yet.', style: t.bodySmall),
            const SizedBox(height: Space.xl),
            FilledButton(
              onPressed: widget.onNewShop,
              child: const Text('Set up a new shop'),
            ),
            const SizedBox(height: Space.md),
            OutlinedButton(
              onPressed: () => setState(() => _restoring = true),
              child: const Text('Restore from a backup'),
            ),
            const SizedBox(height: Space.sm),
            Text(
              'Use this if the old computer broke or Windows was reinstalled. '
              'You will need the backup file and the recovery key you saved.',
              style: t.bodySmall,
            ),
          ],
        ),
      );
    }
    return AuthScaffold(
      width: 560,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Restore from a backup', style: t.titleLarge),
          const SizedBox(height: Space.sm),
          Text(
            'Plug in the drive that holds the backups, then type the path of the newest file.',
            style: t.bodySmall,
          ),
          const SizedBox(height: Space.lg),
          TextField(
            controller: _path,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: 'Backup file',
              hintText: r'E:\Emuktan backups\emuktan-20261010-143000.db',
            ),
          ),
          const SizedBox(height: Space.lg),
          TextField(
            controller: _key,
            style: const TextStyle(fontFamily: 'Consolas'),
            onSubmitted: (_) => _restore(),
            decoration: const InputDecoration(
              labelText: 'Recovery key',
              helperText:
                  'The 8 groups of letters and digits from your printed copy',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: Space.md),
            ErrorLine(_error!),
          ],
          const SizedBox(height: Space.xl),
          Row(
            children: [
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => setState(() => _restoring = false),
                child: const Text('Back'),
              ),
              const SizedBox(width: Space.md),
              Expanded(
                child: FilledButton(
                  onPressed: _busy ? null : _restore,
                  child: Text(_busy ? 'Restoring\u2026' : 'Restore'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A one-time message at start-up, such as the result of a restore.
class NoticeScreen extends StatelessWidget {
  const NoticeScreen({
    super.key,
    required this.message,
    required this.onContinue,
  });
  final String message;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    return AuthScaffold(
      width: 520,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Restore result', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: Space.md),
          Text(message),
          const SizedBox(height: Space.xl),
          FilledButton(onPressed: onContinue, child: const Text('Continue')),
        ],
      ),
    );
  }
}
