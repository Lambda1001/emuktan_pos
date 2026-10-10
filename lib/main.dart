import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_state.dart';
import 'config/brand.dart';
import 'core/bootstrap.dart';
import 'features/gate.dart';
import 'ui/theme/app_theme.dart';

void main() {
  // The scope must sit above MaterialApp: dialogs are pushed onto the app's
  // Navigator, which is an ancestor of `home`, so they can only see providers
  // from a scope that wraps the whole app.
  runApp(const ProviderScope(child: EmuktanApp()));
}

class EmuktanApp extends StatelessWidget {
  const EmuktanApp({super.key, this.open = bootstrap});

  /// Opens the database. Tests pass a version that uses an in-memory one.
  final Future<AppContext> Function() open;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: Brand.name,
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: _Startup(open: open),
    );
  }
}

class _Startup extends ConsumerStatefulWidget {
  const _Startup({required this.open});
  final Future<AppContext> Function() open;

  @override
  ConsumerState<_Startup> createState() => _StartupState();
}

class _StartupState extends ConsumerState<_Startup> {
  AppContext? _app;
  Object? _error;
  bool _recoveryConfirmed = false;

  @override
  void initState() {
    super.initState();
    widget.open().then(
      (app) {
        if (!mounted) return;
        ref.read(appContextProvider.notifier).set(app);
        setState(() => _app = app);
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = e);
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
    final app = _app;
    if (app == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
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
