import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../data/database.dart';
import '../../data/patient_service.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/error_line.dart';
import 'patient_dialogs.dart';
import 'patients_screen.dart' show patientListProvider;

/// Choose who a sale is for: search, or register someone new. Pops the
/// chosen [Patient], or null if cancelled.
class PatientPickerDialog extends ConsumerStatefulWidget {
  const PatientPickerDialog({super.key, required this.me});
  final User me;

  @override
  ConsumerState<PatientPickerDialog> createState() =>
      _PatientPickerDialogState();
}

class _PatientPickerDialogState extends ConsumerState<PatientPickerDialog> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => PatientFormDialog(me: widget.me),
    );
    if (ok != true) return;
    ref.invalidate(patientListProvider);
    // The newest patient is the one just registered.
    final latest = await ref.read(patientServiceProvider).search('', limit: 1);
    if (mounted && latest.isNotEmpty) Navigator.of(context).pop(latest.first);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final q = _search.text.trim();
    final list = ref.watch(patientListProvider(q));
    final now = DateTime.now();
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Who is this sale for?', style: t.titleLarge),
              const SizedBox(height: Space.sm),
              Text(
                'The sale will appear in their record. You can also sell without one.',
                style: t.bodySmall,
              ),
              const SizedBox(height: Space.lg),
              TextField(
                controller: _search,
                autofocus: true,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  hintText: 'Search name, phone or ID',
                  prefixIcon: Icon(Icons.search, size: 20),
                ),
              ),
              const SizedBox(height: Space.md),
              Expanded(
                child: list.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => ErrorLine('Could not load patients. $e'),
                  data: (patients) => patients.isEmpty
                      ? Center(
                          child: Text(
                            q.isEmpty ? 'No patients yet.' : 'Nothing matches.',
                            style: t.bodySmall,
                          ),
                        )
                      : ListView.separated(
                          itemCount: patients.length,
                          separatorBuilder: (_, _) => const Divider(height: 1),
                          itemBuilder: (context, i) {
                            final p = patients[i];
                            final detail = [
                              ?ageText(p, now),
                              ?p.phone,
                            ].join(' · ');
                            return ListTile(
                              title: Text(p.fullName),
                              subtitle: detail.isEmpty ? null : Text(detail),
                              onTap: () => Navigator.of(context).pop(p),
                            );
                          },
                        ),
                ),
              ),
              const SizedBox(height: Space.lg),
              Row(
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: _register,
                    icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                    label: const Text('New patient'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
