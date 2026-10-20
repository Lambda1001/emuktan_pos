import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../config/app_config.dart';
import '../../core/format.dart';
import '../../data/backup_service.dart';
import '../../data/backup_upload.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/error_line.dart';
import '../../ui/widgets/sheet_frame.dart';
import '../stock/stock_widgets.dart';
import 'dart:io';

final _backupListProvider = FutureProvider.autoDispose<List<BackupFile>>((ref) {
  ref.watch(backupStatusProvider); // refresh after each backup
  return ref.watch(backupServiceProvider)?.list() ?? Future.value(const []);
});

final _folderProvider = FutureProvider.autoDispose<String>(
  (ref) => ref.watch(backupServiceProvider)!.folder(),
);

String _size(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
    : '${(bytes / 1024).ceil()} KB';

String _when(DateTime d, DateTime now) {
  final sameDay =
      d.year == now.year && d.month == now.month && d.day == now.day;
  return sameDay
      ? 'today at ${formatTime(d)}'
      : '${formatDate(d)} at ${formatTime(d)}';
}

/// Owner: backups, restore, and a check that the printed recovery key is right.
class BackupPanel extends ConsumerStatefulWidget {
  const BackupPanel({super.key});

  @override
  ConsumerState<BackupPanel> createState() => _BackupPanelState();
}

class _BackupPanelState extends ConsumerState<BackupPanel> {
  final _folder = TextEditingController();
  final _recovery = TextEditingController();
  bool _folderLoaded = false;
  bool _busy = false;
  String? _error;
  ({bool ok, String text})? _keyResult;

  @override
  void dispose() {
    _folder.dispose();
    _recovery.dispose();
    super.dispose();
  }

  void _toast(String m) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m)));

  Future<void> _saveFolder(BackupService svc) async {
    try {
      await svc.setFolder(_folder.text);
      ref.invalidate(_folderProvider);
      ref.invalidate(_backupListProvider);
      setState(() => _error = null);
      _toast('Backup folder saved.');
    } on BackupException catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _backupNow(BackupService svc) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _saveFolderIfChanged(svc);
      final b = await svc.backupNow();
      _toast('Backup saved and checked: ${b.name} (${_size(b.bytes)}).');
      ref.invalidate(backupStatusProvider);
      await _sendOffsite(quiet: true);
    } on BackupException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      ref.invalidate(backupStatusProvider);
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Sends the newest backup to the dashboard server. [quiet] skips the
  /// "nothing to do" messages (used right after a backup).
  Future<void> _sendOffsite({bool quiet = false}) async {
    final up = ref.read(backupUploaderProvider);
    if (up == null) return;
    final r = await up.uploadLatest();
    ref.invalidate(offsiteStatusProvider);
    if (!mounted) return;
    switch (r.outcome) {
      case UploadOutcome.sent:
        _toast('Copy sent to the dashboard server.');
      case UploadOutcome.nothingToSend:
        if (!quiet) _toast('The newest backup is already on the server.');
      case UploadOutcome.notConfigured || UploadOutcome.busy:
        break;
      case UploadOutcome.offline || UploadOutcome.rejected:
        _toast('Not sent to the dashboard: ${r.message}');
    }
  }

  Future<void> _saveFolderIfChanged(BackupService svc) async {
    if (_folder.text.trim() != await svc.folder()) {
      await svc.setFolder(_folder.text);
      ref.invalidate(_folderProvider);
    }
  }

  Future<void> _restore(BackupService svc, File file, DateTime? takenAt) async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _RestoreDialog(file: file, takenAt: takenAt),
    );
    if (done == true) await ref.read(appExitProvider)();
  }

  Future<void> _restoreFromPath(BackupService svc) async {
    final path = await showDialog<String>(
      context: context,
      builder: (_) => const _PathDialog(),
    );
    if (path != null && mounted) await _restore(svc, File(path), null);
  }

  @override
  Widget build(BuildContext context) {
    final svc = ref.watch(backupServiceProvider);
    final t = Theme.of(context).textTheme;
    final c = context.colors;
    if (svc == null) {
      return const Center(
        child: Text('Backups are not available in this session.'),
      );
    }
    final folder = ref.watch(_folderProvider);
    if (!_folderLoaded && folder.hasValue) {
      _folder.text = folder.value!;
      _folderLoaded = true;
    }
    final status = ref.watch(backupStatusProvider).value;
    final list = ref.watch(_backupListProvider).value ?? const <BackupFile>[];
    final now = DateTime.now();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ---- status ----------------------------------------------------
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Space.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text('Backup', style: t.titleLarge)),
                      if (status == null || status.isStale(now))
                        const StatusChip(
                          label: 'Needs attention',
                          icon: Icons.warning_amber_rounded,
                          tone: Tone.warning,
                        )
                      else
                        const StatusChip(
                          label: 'Up to date',
                          icon: Icons.check_circle_outline,
                          tone: Tone.success,
                        ),
                    ],
                  ),
                  const SizedBox(height: Space.sm),
                  Text(
                    status?.lastAt == null
                        ? 'No backup has been taken yet.'
                        : 'Last backup ${_when(status!.lastAt!, now)}, checked and readable.',
                    style: t.bodyMedium,
                  ),
                  const SizedBox(height: Space.xs),
                  Text(
                    'A backup is made automatically about once a day while Emuktan is open, '
                    'and the newest ${BackupConfig.keep} are kept.',
                    style: t.bodySmall,
                  ),
                  if (status?.lastError != null) ...[
                    const SizedBox(height: Space.md),
                    ErrorLine('The last backup failed. ${status!.lastError}'),
                  ],
                  const SizedBox(height: Space.md),
                  _OffsiteLine(onSend: () => _sendOffsite()),
                  const SizedBox(height: Space.xl),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _folder,
                          decoration: const InputDecoration(
                            labelText: 'Backup folder',
                            helperText:
                                'Use a USB drive or another disk, for example E:\\Emuktan backups',
                          ),
                        ),
                      ),
                      const SizedBox(width: Space.md),
                      OutlinedButton(
                        onPressed: () => _saveFolder(svc),
                        child: const Text('Save folder'),
                      ),
                    ],
                  ),
                  FutureBuilder<bool>(
                    future: svc.folderSharesDriveWithData(),
                    builder: (context, snap) => snap.data == true
                        ? Padding(
                            padding: const EdgeInsets.only(top: Space.sm),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(
                                  Icons.warning_amber_rounded,
                                  size: 18,
                                  color: c.warning,
                                ),
                                const SizedBox(width: Space.sm),
                                Expanded(
                                  child: Text(
                                    'This folder is on the same drive as your data. '
                                    'If that disk fails you lose both. Also keep backups on a USB drive.',
                                    style: t.bodySmall!.copyWith(
                                      color: c.warning,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: Space.md),
                    ErrorLine(_error!),
                  ],
                  const SizedBox(height: Space.lg),
                  Row(
                    children: [
                      FilledButton.icon(
                        onPressed: _busy ? null : () => _backupNow(svc),
                        icon: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.backup_outlined, size: 18),
                        label: Text(_busy ? 'Backing up\u2026' : 'Back up now'),
                      ),
                      const SizedBox(width: Space.md),
                      OutlinedButton(
                        onPressed: () => _restoreFromPath(svc),
                        child: const Text('Restore from a file\u2026'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Space.lg),

          // ---- list ------------------------------------------------------
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Space.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Backups in this folder', style: t.titleMedium),
                  const SizedBox(height: Space.sm),
                  if (list.isEmpty)
                    Text('None yet.', style: t.bodySmall)
                  else
                    for (final b in list.take(8)) ...[
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${formatDate(b.takenAt)} at ${formatTime(b.takenAt)}',
                              style: t.bodyMedium,
                            ),
                          ),
                          Text(_size(b.bytes), style: t.bodySmall),
                          const SizedBox(width: Space.md),
                          TextButton(
                            onPressed: () => _restore(svc, b.file, b.takenAt),
                            child: const Text('Restore'),
                          ),
                        ],
                      ),
                      const Divider(),
                    ],
                ],
              ),
            ),
          ),
          const SizedBox(height: Space.lg),

          // ---- recovery key ---------------------------------------------
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Space.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Recovery key', style: t.titleMedium),
                  const SizedBox(height: Space.xs),
                  Text(
                    'Backups cannot be opened without the recovery key you saved on the first day. '
                    'Type it here to confirm your printed copy is right. It is only compared, never stored.',
                    style: t.bodySmall,
                  ),
                  const SizedBox(height: Space.md),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _recovery,
                          obscureText: false,
                          style: const TextStyle(fontFamily: 'Consolas'),
                          onSubmitted: (_) => _checkKey(svc),
                          decoration: const InputDecoration(
                            labelText: 'Recovery key from your printed copy',
                          ),
                        ),
                      ),
                      const SizedBox(width: Space.md),
                      OutlinedButton(
                        onPressed: () => _checkKey(svc),
                        child: const Text('Check key'),
                      ),
                    ],
                  ),
                  if (_keyResult != null) ...[
                    const SizedBox(height: Space.sm),
                    Row(
                      children: [
                        Icon(
                          _keyResult!.ok
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          size: 18,
                          color: _keyResult!.ok ? c.success : c.critical,
                        ),
                        const SizedBox(width: Space.sm),
                        Expanded(
                          child: Text(
                            _keyResult!.text,
                            style: t.bodySmall!.copyWith(
                              color: _keyResult!.ok ? c.success : c.critical,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _checkKey(BackupService svc) {
    final ok = svc.recoveryKeyMatches(_recovery.text);
    setState(
      () => _keyResult = (
        ok: ok,
        text: ok
            ? 'This is the right key. Keep your printed copy somewhere safe, away from this computer.'
            : 'This key does not match. Check each group of 8 characters against your printed copy.',
      ),
    );
    if (ok) _recovery.clear();
  }
}

/// Confirms a restore. It does nothing until the owner agrees, then schedules
/// it for the next start and asks the app to close.
class _RestoreDialog extends ConsumerStatefulWidget {
  const _RestoreDialog({required this.file, required this.takenAt});
  final File file;
  final DateTime? takenAt;

  @override
  ConsumerState<_RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends ConsumerState<_RestoreDialog> {
  String? _error;
  bool _busy = false;

  Future<void> _go() async {
    final app = ref.read(appContextProvider)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await scheduleRestore(app.dataDir, widget.file, app.key!);
      if (mounted) Navigator.of(context).pop(true);
    } on BackupException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final taken = widget.takenAt;
    return SheetFrame(
      title: 'Restore this backup?',
      intro:
          '${taken == null ? widget.file.path : '${formatDate(taken)} at ${formatTime(taken)}'}. '
          'Everything done since then will be replaced by what was in the backup. '
          'Your current data is kept as a safety copy. Emuktan will close; open it again to finish.',
      actionLabel: 'Restore and close',
      destructive: true,
      busy: _busy,
      error: _error,
      onAction: _go,
      children: const [],
    );
  }
}

class _PathDialog extends StatefulWidget {
  const _PathDialog();

  @override
  State<_PathDialog> createState() => _PathDialogState();
}

class _PathDialogState extends State<_PathDialog> {
  final _path = TextEditingController();

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SheetFrame(
      title: 'Restore from a file',
      intro:
          'Type the full path of a backup file, for example E:\\Emuktan backups\\emuktan-20261010-143000.db',
      actionLabel: 'Continue',
      onAction: () {
        final p = _path.text.trim().replaceAll('"', '');
        if (p.isNotEmpty) Navigator.of(context).pop(p);
      },
      children: [
        TextField(
          controller: _path,
          autofocus: true,
          onSubmitted: (_) {
            final p = _path.text.trim().replaceAll('"', '');
            if (p.isNotEmpty) Navigator.of(context).pop(p);
          },
          decoration: const InputDecoration(labelText: 'Backup file'),
        ),
      ],
    );
  }
}

/// The offsite copy on the dashboard server: off, waiting, or stored.
class _OffsiteLine extends ConsumerWidget {
  const _OffsiteLine({required this.onSend});
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final configured = ref.watch(syncStatusProvider).value?.configured ?? false;
    final st = ref.watch(offsiteStatusProvider).value;
    if (!configured) {
      return Text(
        'Offsite copy is off. Enter the dashboard address and key under Dashboard '
        'in these settings to also keep an encrypted copy of each backup on the dashboard server.',
        style: t.bodySmall,
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          st?.sentAt == null
              ? 'No copy has reached the dashboard server yet.'
              : 'Copy on the dashboard server: ${st!.name}, sent ${_when(st.sentAt!, DateTime.now())}. '
                    'It stays encrypted; the server cannot read it.',
          style: t.bodyMedium,
        ),
        if (st?.error != null) ...[
          const SizedBox(height: Space.sm),
          ErrorLine(
            'The latest copy could not be sent. ${st!.error} It is retried automatically.',
          ),
        ],
        TextButton(
          onPressed: onSend,
          child: const Text('Send latest backup to the dashboard now'),
        ),
      ],
    );
  }
}
