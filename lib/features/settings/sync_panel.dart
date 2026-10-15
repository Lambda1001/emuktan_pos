import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../core/format.dart';
import '../../data/sync_service.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/error_line.dart';

/// Owner: connect this PC to the web dashboard, and see whether it is keeping up.
class SyncPanel extends ConsumerStatefulWidget {
  const SyncPanel({super.key});

  @override
  ConsumerState<SyncPanel> createState() => _SyncPanelState();
}

class _SyncPanelState extends ConsumerState<SyncPanel> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  bool _loaded = false;
  bool _busy = false;
  String? _error, _ok;

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String?> Function(SyncService svc) job) async {
    final svc = ref.read(syncServiceProvider)!;
    setState(() {
      _busy = true;
      _error = null;
      _ok = null;
    });
    try {
      final msg = await job(svc);
      if (mounted) setState(() => _ok = msg);
    } on SyncException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      ref.invalidate(syncStatusProvider);
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load(SyncService svc) async {
    _loaded = true;
    final cfg = await svc.config();
    if (cfg != null && mounted) {
      _url.text = cfg.url;
      _key.text = cfg.key;
    }
  }

  @override
  Widget build(BuildContext context) {
    final svc = ref.watch(syncServiceProvider);
    final t = Theme.of(context).textTheme;
    final c = context.colors;
    if (svc == null) {
      return const Center(child: Text('Not available in this session.'));
    }
    if (!_loaded) _load(svc);
    final status = ref.watch(syncStatusProvider).value;
    final now = DateTime.now();

    final String summary;
    var warn = false;
    if (status == null || !status.configured) {
      summary = 'Not connected. Sales and stock are not being sent anywhere.';
    } else if (status.lastOkAt == null) {
      summary = 'Connected, but nothing has been sent yet.';
      warn = true;
    } else {
      final d = status.lastOkAt!;
      summary = 'Last sent ${formatDate(d)} at ${formatTime(d)}.';
      warn = status.isStale(now);
    }

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Space.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Web dashboard', style: t.titleMedium),
                  const SizedBox(height: Space.sm),
                  Text(
                    'Sends sales and stock to the dashboard so they can be '
                    'seen from a phone. Patient records are never sent.',
                    style: t.bodySmall,
                  ),
                  const SizedBox(height: Space.lg),
                  Text(
                    summary,
                    style: t.bodyMedium?.copyWith(
                      color: warn ? c.warning : null,
                    ),
                  ),
                  if (status != null && status.configured) ...[
                    const SizedBox(height: Space.xs),
                    Text(
                      status.pending == 0
                          ? 'Nothing waiting.'
                          : '${status.pending} changes waiting to be sent.',
                      style: t.bodySmall,
                    ),
                    if (status.lastError != null)
                      Text(status.lastError!, style: t.bodySmall),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: Space.lg),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(Space.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _url,
                    decoration: const InputDecoration(
                      labelText: 'Dashboard address',
                      hintText: 'https://dashboard.example.co.ke',
                    ),
                  ),
                  const SizedBox(height: Space.md),
                  TextField(
                    controller: _key,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Key from the dashboard',
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: Space.md),
                    ErrorLine(_error!),
                  ],
                  if (_ok != null) ...[
                    const SizedBox(height: Space.md),
                    Text(_ok!, style: t.bodySmall),
                  ],
                  const SizedBox(height: Space.lg),
                  Wrap(
                    spacing: Space.md,
                    runSpacing: Space.sm,
                    children: [
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _run((s) async {
                                final name = await s.testConnection(
                                  url: _url.text,
                                  key: _key.text,
                                );
                                return 'Connected to $name.';
                              }),
                        child: const Text('Test connection'),
                      ),
                      FilledButton(
                        onPressed: _busy
                            ? null
                            : () => _run((s) async {
                                await s.configure(
                                  url: _url.text,
                                  key: _key.text,
                                );
                                final r = await s.syncNow();
                                return r.outcome == SyncOutcome.ok
                                    ? 'Saved. ${r.sent} changes sent.'
                                    : 'Saved. ${r.message ?? 'Will try again shortly.'}';
                              }),
                        child: const Text('Save and send'),
                      ),
                      if (status != null && status.configured) ...[
                        OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => _run((s) async {
                                  final r = await s.syncNow();
                                  return r.outcome == SyncOutcome.ok
                                      ? '${r.sent} changes sent.'
                                      : r.message;
                                }),
                          child: const Text('Send now'),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _run((s) async {
                                  await s.clear();
                                  _url.clear();
                                  _key.clear();
                                  return 'Disconnected.';
                                }),
                          child: const Text('Disconnect'),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
