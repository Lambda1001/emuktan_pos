import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/bootstrap.dart';
import 'ui/theme/app_theme.dart';

void main() {
  runApp(const EmuktanApp());
}

class EmuktanApp extends StatelessWidget {
  const EmuktanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Emuktan',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const _Startup(),
    );
  }
}

class _Startup extends StatefulWidget {
  const _Startup();

  @override
  State<_Startup> createState() => _StartupState();
}

class _StartupState extends State<_Startup> {
  late final Future<AppContext> _future = bootstrap();
  bool _recoveryConfirmed = false;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppContext>(
      future: _future,
      builder: (context, snap) {
        if (snap.hasError) {
          return _Message(
            title: 'Cannot open the database',
            body: '${snap.error}\n\nDo not delete any files. Contact support.',
          );
        }
        if (!snap.hasData) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        final app = snap.data!;
        final recovery = app.newRecoveryKey;
        if (recovery != null && !_recoveryConfirmed) {
          return _RecoveryKeyScreen(
            recoveryKey: recovery,
            onConfirmed: () => setState(() => _recoveryConfirmed = true),
          );
        }
        return _Message(
          title: 'Emuktan',
          body: 'Encrypted database is open.\nData folder: ${app.dataDir.path}',
        );
      },
    );
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
  const _RecoveryKeyScreen({required this.recoveryKey, required this.onConfirmed});
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
                Text('Save your recovery key',
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 12),
                const Text(
                    'All patient and sales data is encrypted. If this computer is lost or '
                    'Windows is reinstalled, this key is the ONLY way to open the data and '
                    'its backups. Write it down or print it, and keep it somewhere safe '
                    'away from this computer.'),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).colorScheme.outline),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(recoveryKey,
                      style: const TextStyle(fontFamily: 'Consolas', fontSize: 18)),
                ),
                const SizedBox(height: 12),
                Row(children: [
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
                ]),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
