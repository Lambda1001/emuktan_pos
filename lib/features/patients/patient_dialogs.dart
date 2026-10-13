import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../core/format.dart';
import '../../data/database.dart';
import '../../data/patient_service.dart';
import '../../data/tables.dart';
import '../../ui/theme/app_tokens.dart';
import '../../ui/widgets/error_line.dart';
import '../../ui/widgets/sheet_frame.dart';

/// Clinical details (allergies, conditions, visits and notes) are for the
/// nurse / clinician and the owner. Cashiers register and find patients.
bool canSeeClinical(Role role) => role != Role.cashier;

String sexLabel(Sex s) => switch (s) {
  Sex.female => 'Female',
  Sex.male => 'Male',
  Sex.other => 'Other',
};

final patientProvider = FutureProvider.autoDispose.family<Patient?, int>(
  (ref, id) => ref.watch(patientServiceProvider).get(id),
);

final patientVisitsProvider = FutureProvider.autoDispose
    .family<List<VisitRecord>, int>(
      (ref, id) => ref.watch(patientServiceProvider).visits(id),
    );

final patientSalesProvider = FutureProvider.autoDispose
    .family<List<Sale>, int>(
      (ref, id) => ref.watch(patientServiceProvider).sales(id),
    );

/// Register a patient ([existing] null) or change their details.
class PatientFormDialog extends ConsumerStatefulWidget {
  const PatientFormDialog({super.key, required this.me, this.existing});
  final User me;
  final Patient? existing;

  @override
  ConsumerState<PatientFormDialog> createState() => _PatientFormDialogState();
}

class _PatientFormDialogState extends ConsumerState<PatientFormDialog> {
  late final _name = TextEditingController(text: widget.existing?.fullName);
  late final _phone = TextEditingController(text: widget.existing?.phone);
  late final _nationalId = TextEditingController(
    text: widget.existing?.nationalId,
  );
  late final _dob = TextEditingController(
    text: widget.existing?.dateOfBirth == null
        ? ''
        : formatDateInput(widget.existing!.dateOfBirth!),
  );
  late final _age = TextEditingController(
    text: widget.existing?.approxAgeYears?.toString() ?? '',
  );
  late final _allergies = TextEditingController(
    text: widget.existing?.allergies,
  );
  late final _conditions = TextEditingController(
    text: widget.existing?.chronicConditions,
  );
  late Sex? _sex = widget.existing?.sex;
  String? _error;
  bool _busy = false;

  bool get _isNew => widget.existing == null;
  bool get _clinical => canSeeClinical(widget.me.role);

  @override
  void dispose() {
    for (final c in [
      _name,
      _phone,
      _nationalId,
      _dob,
      _age,
      _allergies,
      _conditions,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    DateTime? dob;
    if (_dob.text.trim().isNotEmpty) {
      dob = parseDate(_dob.text);
      if (dob == null) {
        setState(
          () => _error = 'Write the date of birth like 07/10/1990, or leave it empty.',
        );
        return;
      }
    }
    final ageText = _age.text.trim();
    final age = ageText.isEmpty ? null : int.tryParse(ageText);
    if (ageText.isNotEmpty && age == null) {
      setState(() => _error = 'The age must be a whole number.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final svc = ref.read(patientServiceProvider);
    final input = PatientInput(
      fullName: _name.text,
      phone: _phone.text,
      nationalId: _nationalId.text,
      dateOfBirth: dob,
      approxAgeYears: age,
      sex: _sex,
      allergies: _allergies.text,
      chronicConditions: _conditions.text,
    );
    try {
      if (_isNew) {
        await svc.register(input, userId: widget.me.id);
      } else {
        await svc.update(
          widget.existing!.id,
          input,
          includeClinical: _clinical,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      final msg = userMessage(e);
      if (msg == null) rethrow;
      if (mounted) setState(() => _error = msg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return SheetFrame(
      title: _isNew ? 'Register patient' : 'Edit ${widget.existing!.fullName}',
      intro: _isNew
          ? 'Only the name is needed. Add the rest if you have it.'
          : 'Change any detail, then save.',
      actionLabel: _isNew ? 'Register' : 'Save changes',
      onAction: _save,
      error: _error,
      busy: _busy,
      maxWidth: 520,
      children: [
        TextField(
          controller: _name,
          autofocus: true,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Full name'),
        ),
        const SizedBox(height: Space.lg),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'Phone'),
              ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: TextField(
                controller: _nationalId,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'National ID'),
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.lg),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _dob,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Date of birth',
                  hintText: 'DD/MM/YYYY',
                ),
              ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: TextField(
                controller: _age,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.next,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(3),
                ],
                decoration: const InputDecoration(
                  labelText: 'Age, if date unknown',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.lg),
        Text('Sex', style: t.labelMedium),
        const SizedBox(height: Space.sm),
        SegmentedButton<Sex?>(
          showSelectedIcon: false,
          emptySelectionAllowed: true,
          segments: [
            for (final s in Sex.values)
              ButtonSegment(value: s, label: Text(sexLabel(s))),
          ],
          selected: {?_sex},
          onSelectionChanged: (s) => setState(() => _sex = s.firstOrNull),
        ),
        if (_clinical) ...[
          const SizedBox(height: Space.lg),
          TextField(
            controller: _allergies,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Allergies',
              hintText: 'For example: penicillin',
            ),
          ),
          const SizedBox(height: Space.lg),
          TextField(
            controller: _conditions,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Long-term conditions',
              hintText: 'For example: hypertension, diabetes',
            ),
          ),
        ],
      ],
    );
  }
}

/// Record a visit: vitals, and notes when a clinician is writing.
class VisitDialog extends ConsumerStatefulWidget {
  const VisitDialog({super.key, required this.patient, required this.me});
  final Patient patient;
  final User me;

  @override
  ConsumerState<VisitDialog> createState() => _VisitDialogState();
}

class _VisitDialogState extends ConsumerState<VisitDialog> {
  final _weight = TextEditingController();
  final _sys = TextEditingController();
  final _dia = TextEditingController();
  final _notes = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _weight.dispose();
    _sys.dispose();
    _dia.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final w = _weight.text.trim();
    final weight = w.isEmpty ? null : double.tryParse(w);
    final sys = int.tryParse(_sys.text.trim());
    final dia = int.tryParse(_dia.text.trim());
    if (w.isNotEmpty && weight == null) {
      setState(() => _error = 'The weight must be a number, like 62.5.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(patientServiceProvider)
          .recordVisit(
            widget.patient.id,
            userId: widget.me.id,
            weightKg: weight,
            bpSystolic: sys,
            bpDiastolic: dia,
            notes: _notes.text,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      final msg = userMessage(e);
      if (msg == null) rethrow;
      if (mounted) setState(() => _error = msg);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final digits = [FilteringTextInputFormatter.digitsOnly];
    return SheetFrame(
      title: 'Record visit',
      intro: 'For ${widget.patient.fullName}. Fill in what was taken today.',
      actionLabel: 'Save visit',
      onAction: _save,
      error: _error,
      busy: _busy,
      children: [
        TextField(
          controller: _weight,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(labelText: 'Weight (kg)'),
        ),
        const SizedBox(height: Space.lg),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _sys,
                keyboardType: TextInputType.number,
                inputFormatters: digits,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Blood pressure, top',
                ),
              ),
            ),
            const SizedBox(width: Space.md),
            Expanded(
              child: TextField(
                controller: _dia,
                keyboardType: TextInputType.number,
                inputFormatters: digits,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Blood pressure, bottom',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.lg),
        TextField(
          controller: _notes,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            labelText: 'Notes',
            alignLabelWithHint: true,
          ),
        ),
      ],
    );
  }
}

/// One patient: details, and for clinical staff the visits and notes.
class PatientDetailDialog extends ConsumerWidget {
  const PatientDetailDialog({super.key, required this.patientId, required this.me});
  final int patientId;
  final User me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Theme.of(context).textTheme;
    final c = context.colors;
    final patient = ref.watch(patientProvider(patientId));
    final clinical = canSeeClinical(me.role);

    Future<void> open(Widget dialog) async {
      final ok = await showDialog<bool>(context: context, builder: (_) => dialog);
      if (ok != true) return;
      ref
        ..invalidate(patientProvider(patientId))
        ..invalidate(patientVisitsProvider(patientId));
    }

    return patient.when(
      loading: () => const Dialog(
        child: Padding(
          padding: EdgeInsets.all(Space.xxl),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (e, _) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(Space.xl),
          child: ErrorLine('Could not load this patient. $e'),
        ),
      ),
      data: (p) {
        if (p == null) {
          return const Dialog(
            child: Padding(
              padding: EdgeInsets.all(Space.xl),
              child: Text('That patient no longer exists.'),
            ),
          );
        }
        final now = DateTime.now();
        final facts = [
          ?ageText(p, now),
          ?(p.sex == null ? null : sexLabel(p.sex!)),
        ].join(' · ');
        return SheetFrame(
          title: p.fullName,
          intro: facts.isEmpty ? 'Age and sex not recorded.' : facts,
          maxWidth: 560,
          cancelLabel: 'Close',
          actionLabel: clinical ? 'Record visit' : '',
          onAction: () => open(VisitDialog(patient: p, me: me)),
          extraActions: [
            OutlinedButton(
              onPressed: () => open(PatientFormDialog(me: me, existing: p)),
              child: const Text('Edit'),
            ),
          ],
          children: [
            _Fact('Phone', p.phone),
            _Fact('National ID', p.nationalId),
            _Fact(
              'Registered',
              formatDate(p.createdAt),
            ),
            if (clinical) ...[
              const SizedBox(height: Space.md),
              const Divider(),
              const SizedBox(height: Space.md),
              _Fact('Allergies', p.allergies, emphasise: p.allergies != null),
              _Fact('Long-term conditions', p.chronicConditions),
              const SizedBox(height: Space.md),
              Text('Visits', style: t.titleMedium),
              const SizedBox(height: Space.sm),
              ref
                  .watch(patientVisitsProvider(patientId))
                  .when(
                    loading: () => const LinearProgressIndicator(),
                    error: (e, _) => ErrorLine('Could not load visits. $e'),
                    data: (visits) => visits.isEmpty
                        ? Text('No visits recorded yet.', style: t.bodySmall)
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [for (final v in visits) _VisitTile(v)],
                          ),
                  ),
            ],
            const SizedBox(height: Space.md),
            const Divider(),
            const SizedBox(height: Space.md),
            Text('Purchases', style: t.titleMedium),
            const SizedBox(height: Space.sm),
            ref
                .watch(patientSalesProvider(patientId))
                .when(
                  loading: () => const LinearProgressIndicator(),
                  error: (e, _) => ErrorLine('Could not load purchases. $e'),
                  data: (sales) => sales.isEmpty
                      ? Text('No purchases linked yet.', style: t.bodySmall)
                      : Column(
                          children: [
                            for (final s in sales.take(8))
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: Space.xs,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '${s.receiptNo}  ·  ${formatDate(s.createdAt)}',
                                        style: t.bodyMedium,
                                      ),
                                    ),
                                    Text(
                                      s.status == SaleStatus.voided
                                          ? 'Cancelled'
                                          : formatKes(s.totalCents),
                                      style: t.bodyMedium!.copyWith(
                                        color: s.status == SaleStatus.voided
                                            ? c.textTertiary
                                            : null,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                ),
          ],
        );
      },
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact(this.label, this.value, {this.emphasise = false});
  final String label;
  final String? value;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 160, child: Text(label, style: t.bodySmall)),
          Expanded(
            child: value == null
                ? Text('-', style: t.bodyMedium!.copyWith(color: c.textTertiary))
                : emphasise
                ? Row(
                    children: [
                      Icon(Icons.warning_amber_rounded, size: 16, color: c.warning),
                      const SizedBox(width: Space.xs),
                      Expanded(child: Text(value!, style: t.bodyMedium)),
                    ],
                  )
                : Text(value!, style: t.bodyMedium),
          ),
        ],
      ),
    );
  }
}

class _VisitTile extends StatelessWidget {
  const _VisitTile(this.v);
  final VisitRecord v;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final x = v.visit;
    final vitals = [
      if (x.weightKg != null) '${x.weightKg!.toStringAsFixed(1)} kg',
      if (x.bpSystolic != null) 'BP ${x.bpSystolic}/${x.bpDiastolic}',
    ].join('   ');
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${formatDate(x.visitedAt)} ${formatTime(x.visitedAt)}  ·  ${v.recordedBy}',
            style: t.labelMedium,
          ),
          if (vitals.isNotEmpty) Text(vitals, style: t.bodyMedium),
          for (final n in v.notes) Text(n.text, style: t.bodyMedium),
        ],
      ),
    );
  }
}
