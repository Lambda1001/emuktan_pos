import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_state.dart';
import 'config/app_config.dart';
import 'config/brand.dart';
import 'core/bootstrap.dart';
import 'features/gate.dart';
import 'features/startup/first_run_screen.dart';
import 'ui/theme/app_theme.dart';

void main() {
  // The scope must sit above MaterialApp: dialogs are pushed onto the app's
  // Navigator, which is an ancestor of `home`, so they can only see providers
  // from a scope that wraps the whole app.
  runApp(ProviderScope(child: EmuktanApp(firstRun: FirstRunHooks.real())));
}

class EmuktanApp extends StatelessWidget {
  const EmuktanApp({super.key, this.open = bootstrap, this.firstRun});

  /// Opens the database. Tests pass a version that uses an in-memory one.
  final Future<AppContext> Function() open;

  /// Offers "restore from a backup" on a PC with no data. Null in tests.
  final FirstRunHooks? firstRun;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: Brand.name,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: _Startup(open: open, firstRun: firstRun),
    );
  }
}

class _Startup extends ConsumerStatefulWidget {
  const _Startup({required this.open, this.firstRun});
  final Future<AppContext> Function() open;
  final FirstRunHooks? firstRun;

  @override
  ConsumerState<_Startup> createState() => _StartupState();
}

class _StartupState extends ConsumerState<_Startup> {
  AppContext? _app;
  Object? _error;
  bool _recoveryConfirmed = false;
  bool _noticeSeen = false;
  bool _askFirstRun = false;
  Timer? _backupTimer;
  Timer? _syncTimer;
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void dispose() {
    _backupTimer?.cancel();
    _syncTimer?.cancel();
    _lifecycle?.dispose();
    super.dispose();
  }

  /// A PC with no data is offered "restore" before anything is created.
  Future<void> _begin() async {
    try {
      final hooks = widget.firstRun;
      if (hooks != null && await hooks.isFirstRun()) {
        if (mounted) setState(() => _askFirstRun = true);
        return;
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
      return;
    }
    _open();
  }

  void _open() {
    widget.open().then(
      (app) {
        if (!mounted) return;
        ref.read(appContextProvider.notifier).set(app);
        setState(() => _app = app);
        _startBackups();
        _startSync();
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = e);
      },
    );
  }

  /// One backup check now, then every half hour while the app is open.
  void _startBackups() {
    final svc = ref.read(backupServiceProvider);
    if (svc == null) return;
    final uploader = ref.read(backupUploaderProvider);
    Future<void> check() async {
      await svc.runIfDue();
      if (mounted) ref.invalidate(backupStatusProvider);
      // Also retries a copy that could not be sent earlier (offline). A no-op
      // when the newest backup is already on the server or sync is not set up.
      await uploader?.uploadLatest();
      if (mounted) ref.invalidate(offsiteStatusProvider);
    }

    check();
    _backupTimer = Timer.periodic(BackupConfig.checkEvery, (_) => check());
  }

  /// Push to the dashboard now, then every few minutes while the app is open,
  /// and once more as the window closes (the PC may be off overnight). A
  /// failure is recorded and shown in the status bar, never as a dialog.
  void _startSync() {
    final svc = ref.read(syncServiceProvider);
    if (svc == null) return;
    Future<void> push() async {
      await svc.syncNow();
      if (mounted) ref.invalidate(syncStatusProvider);
    }

    push();
    _syncTimer = Timer.periodic(SyncConfig.every, (_) => push());
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        try {
          await svc.syncNow().timeout(const Duration(seconds: 5));
        } catch (_) {}
        return AppExitResponse.exit;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return _Message(
        title: 'Cannot open the database',
        body: '$_error\n\nDo not delete any files. Contact support.',
      );
    }
    if (_askFirstRun) {
      return FirstRunScreen(
        onNewShop: () {
          setState(() => _askFirstRun = false);
          _open();
        },
        onRestore: (path, key) async {
          await widget.firstRun!.restore(path, key);
          if (!mounted) return;
          setState(() => _askFirstRun = false);
          _open();
        },
      );
    }
    final app = _app;
    if (app == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final notice = app.notice;
    if (notice != null && !_noticeSeen) {
      return NoticeScreen(
        message: notice,
        onContinue: () => setState(() => _noticeSeen = true),
      );
    }
    final recovery = app.newRecoveryKey;
    if (recovery != null && !_recoveryConfirmed) {
      return _RecoveryKeyScreen(
        recoveryKey: recovery,
        onConfirmed: () => setState(() => _recoveryConfirmed = true),
      );
    }
    return const Gate();
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 12),
                SelectableText(body),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecoveryKeyScreen extends StatelessWidget {
  const _RecoveryKeyScreen({
    required this.recoveryKey,
    required this.onConfirmed,
  });
  final String recoveryKey;
  final VoidCallback onConfirmed;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Save your recovery key',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                const Text(
                  'All patient and sales data is encrypted. If this computer is lost or '
                  'Windows is reinstalled, this key is the ONLY way to open the data and '
                  'its backups. Write it down or print it, and keep it somewhere safe '
                  'away from this computer.',
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outline,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    recoveryKey,
                    style: const TextStyle(
                      fontFamily: 'Consolas',
                      fontSize: 18,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OutlinedButton(
                      onPressed: () =>
                          Clipboard.setData(ClipboardData(text: recoveryKey)),
                      child: const Text('Copy'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: onConfirmed,
                      child: const Text('I have saved it'),
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
}
