import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../data/database.dart';
import '../../data/patient_service.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/error_line.dart';
import 'patient_dialogs.dart';

final patientListProvider = FutureProvider.autoDispose
    .family<List<Patient>, String>(
      (ref, query) => ref.watch(patientServiceProvider).search(query),
    );

/// Find, register and open patients. Everyone can register and search; the
/// clinical record opens for nurses / clinicians and the owner (DESIGN.md
/// section 3).
class PatientsScreen extends ConsumerStatefulWidget {
  const PatientsScreen({super.key, required this.me});
  final User me;

  @override
  ConsumerState<PatientsScreen> createState() => _PatientsScreenState();
}

class _PatientsScreenState extends ConsumerState<PatientsScreen> {
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
    if (mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('Patient registered.')));
    }
  }

  Future<void> _open(Patient p) async {
    await showDialog<void>(
      context: context,
      builder: (_) => PatientDetailDialog(patientId: p.id, me: widget.me),
    );
    ref.invalidate(patientListProvider);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final q = _search.text.trim();
    final list = ref.watch(patientListProvider(q));
    final now = DateTime.now();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: TextField(
                  controller: _search,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Search name, phone or ID',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () => setState(_search.clear),
                          ),
                  ),
                ),
              ),
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _register,
              icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
              label: const Text('Register patient'),
            ),
          ],
        ),
        const SizedBox(height: Space.lg),
        Expanded(
          child: Card(
            clipBehavior: Clip.antiAlias,
            child: list.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(Space.xl),
                child: ErrorLine('Could not load patients. $e'),
              ),
              data: (patients) => patients.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.people_outline,
                            size: 40,
                            color: context.colors.textTertiary,
                          ),
                          const SizedBox(height: Space.md),
                          Text(
                            q.isEmpty ? 'No patients yet' : 'Nothing matches',
                            style: t.titleMedium,
                          ),
                          const SizedBox(height: Space.xs),
                          Text(
                            q.isEmpty
                                ? 'Register the first patient to start their record.'
                                : 'Check the spelling, or register them as new.',
                            style: t.bodySmall,
                          ),
                        ],
                      ),
                    )
                  : Column(
                      children: [
                        const _Header(),
                        const Divider(),
                        Expanded(
                          child: ListView.separated(
                            itemCount: patients.length,
                            separatorBuilder: (_, _) => const Divider(),
                            itemBuilder: (context, i) => _Row(
                              p: patients[i],
                              now: now,
                              showAllergy: canSeeClinical(widget.me.role),
                              onTap: () => _open(patients[i]),
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
        if (list.hasValue && list.value!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Space.sm),
            child: Text(
              q.isEmpty
                  ? 'Showing the most recently registered'
                  : '${list.value!.length} found',
              style: t.labelSmall,
            ),
          ),
      ],
    );
  }
}

const _pad = EdgeInsets.symmetric(horizontal: Space.lg);

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).textTheme.labelSmall!;
    return Padding(
      padding: _pad,
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            Expanded(flex: 4, child: Text('Name', style: s)),
            Expanded(flex: 2, child: Text('Age', style: s)),
            Expanded(flex: 2, child: Text('Sex', style: s)),
            Expanded(flex: 3, child: Text('Phone', style: s)),
            Expanded(flex: 3, child: Text('National ID', style: s)),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.p,
    required this.now,
    required this.showAllergy,
    required this.onTap,
  });
  final Patient p;
  final DateTime now;
  final bool showAllergy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = context.colors;
    Widget cell(int flex, String? text) => Expanded(
      flex: flex,
      child: Text(
        text ?? '-',
        overflow: TextOverflow.ellipsis,
        style: t.bodyMedium!.copyWith(
          color: text == null ? c.textTertiary : null,
        ),
      ),
    );
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: _pad,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              Expanded(
                flex: 4,
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        p.fullName,
                        overflow: TextOverflow.ellipsis,
                        style: t.titleMedium,
                      ),
                    ),
                    if (showAllergy && p.allergies != null) ...[
                      const SizedBox(width: Space.sm),
                      Tooltip(
                        message: 'Allergies: ${p.allergies}',
                        child: Icon(
                          Icons.warning_amber_rounded,
                          size: 18,
                          color: c.warning,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              cell(2, ageText(p, now)),
              cell(2, p.sex == null ? null : sexLabel(p.sex!)),
              cell(3, p.phone),
              cell(3, p.nationalId),
            ],
          ),
        ),
      ),
    );
  }
}
