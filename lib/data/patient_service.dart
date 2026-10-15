import 'package:drift/drift.dart';

import 'database.dart';
import 'tables.dart';

/// A patient rule was broken. The message is shown to the user as written.
class PatientRuleException implements Exception {
  PatientRuleException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What staff enter when registering or editing a patient.
class PatientInput {
  const PatientInput({
    required this.fullName,
    this.phone,
    this.nationalId,
    this.dateOfBirth,
    this.approxAgeYears,
    this.sex,
    this.allergies,
    this.chronicConditions,
  });

  final String fullName;
  final String? phone, nationalId, allergies, chronicConditions;
  final DateTime? dateOfBirth;
  final int? approxAgeYears;
  final Sex? sex;
}

/// One visit with the notes written during it.
class VisitRecord {
  const VisitRecord({
    required this.visit,
    required this.recordedBy,
    required this.notes,
  });
  final Visit visit;
  final String recordedBy;
  final List<VisitNote> notes;
}

class VisitNote {
  const VisitNote({required this.clinicianName, required this.text});
  final String clinicianName, text;
}

/// Registering patients, finding them, and keeping their visits.
class PatientService {
  PatientService(this._db, {DateTime Function()? clock})
    : _now = clock ?? DateTime.now;

  final AppDatabase _db;
  final DateTime Function() _now;

  static String? _clean(String? s) {
    final t = s?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// Keeps digits and a leading plus, so "0712 345 678" and "0712-345-678"
  /// find the same patient.
  static String? _cleanPhone(String? s) {
    final t = _clean(s);
    if (t == null) return null;
    return t.replaceAll(RegExp(r'[^\d+]'), '');
  }

  PatientInput _checked(PatientInput i) {
    final name = i.fullName.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (name.length < 2) {
      throw PatientRuleException('Enter the patient\'s full name.');
    }
    final phone = _cleanPhone(i.phone);
    if (phone != null && RegExp(r'\d').allMatches(phone).length < 7) {
      throw PatientRuleException(
        'That phone number looks too short. Check it, or leave it empty.',
      );
    }
    final dob = i.dateOfBirth;
    if (dob != null && dob.isAfter(_now())) {
      throw PatientRuleException('The date of birth cannot be in the future.');
    }
    final age = i.approxAgeYears;
    if (age != null && (age < 0 || age > 120)) {
      throw PatientRuleException('Enter an age between 0 and 120.');
    }
    return PatientInput(
      fullName: name,
      phone: phone,
      nationalId: _clean(i.nationalId),
      // An exact date of birth makes a guessed age pointless.
      dateOfBirth: dob,
      approxAgeYears: dob == null ? age : null,
      sex: i.sex,
      allergies: _clean(i.allergies),
      chronicConditions: _clean(i.chronicConditions),
    );
  }

  // ---- Reading ----------------------------------------------------------

  /// Patients whose name, phone or ID contains [query], by name. An empty
  /// query lists the most recently registered first.
  Future<List<Patient>> search(String query, {int limit = 200}) {
    final q = query.trim();
    final select = _db.select(_db.patients);
    if (q.isEmpty) {
      select.orderBy([(p) => OrderingTerm.desc(p.id)]);
    } else {
      final like = '%${q.replaceAll('%', '').replaceAll('_', '')}%';
      final digits = q.replaceAll(RegExp(r'[^\d+]'), '');
      select
        ..where(
          (p) =>
              p.fullName.like(like) |
              p.nationalId.like(like) |
              (digits.length >= 3
                  ? p.phone.like('%$digits%')
                  : p.id.equals(-1)),
        )
        ..orderBy([(p) => OrderingTerm.asc(p.fullName)]);
    }
    return (select..limit(limit)).get();
  }

  Future<Patient?> get(int id) => (_db.select(
    _db.patients,
  )..where((p) => p.id.equals(id))).getSingleOrNull();

  /// Visits newest first, each with its consultation notes.
  Future<List<VisitRecord>> visits(int patientId) async {
    final visits =
        await (_db.select(_db.visits)
              ..where((v) => v.patientId.equals(patientId))
              ..orderBy([(v) => OrderingTerm.desc(v.visitedAt)]))
            .get();
    if (visits.isEmpty) return const [];
    final users = {
      for (final u in await _db.select(_db.users).get()) u.id: u.displayName,
    };
    final notes = await (_db.select(
      _db.consultations,
    )..where((c) => c.visitId.isIn(visits.map((v) => v.id)))).get();
    return [
      for (final v in visits)
        VisitRecord(
          visit: v,
          recordedBy: users[v.createdBy] ?? 'Unknown',
          notes: [
            for (final n in notes.where((n) => n.visitId == v.id))
              VisitNote(
                clinicianName: users[n.clinicianId] ?? 'Unknown',
                text: n.notes,
              ),
          ],
        ),
    ];
  }

  /// Sales linked to this patient, newest first.
  Future<List<Sale>> sales(int patientId) =>
      (_db.select(_db.sales)
            ..where((s) => s.patientId.equals(patientId))
            ..orderBy([(s) => OrderingTerm.desc(s.id)])
            ..limit(100))
          .get();

  // ---- Writing ----------------------------------------------------------

  Future<Patient> register(PatientInput input, {required int userId}) async {
    final i = _checked(input);
    final id = await _db
        .into(_db.patients)
        .insert(
          PatientsCompanion.insert(
            fullName: i.fullName,
            phone: Value(i.phone),
            nationalId: Value(i.nationalId),
            dateOfBirth: Value(i.dateOfBirth),
            approxAgeYears: Value(i.approxAgeYears),
            sex: Value(i.sex),
            allergies: Value(i.allergies),
            chronicConditions: Value(i.chronicConditions),
            createdBy: userId,
            createdAt: Value(_now()),
            updatedAt: Value(_now()),
          ),
        );
    return (await get(id))!;
  }

  /// Changes details. Pass [includeClinical] false (a cashier) to leave the
  /// allergies and conditions exactly as they are.
  Future<void> update(
    int id,
    PatientInput input, {
    required bool includeClinical,
  }) async {
    final i = _checked(input);
    final n = await (_db.update(_db.patients)..where((p) => p.id.equals(id)))
        .write(
          PatientsCompanion(
            fullName: Value(i.fullName),
            phone: Value(i.phone),
            nationalId: Value(i.nationalId),
            dateOfBirth: Value(i.dateOfBirth),
            approxAgeYears: Value(i.approxAgeYears),
            sex: Value(i.sex),
            allergies: includeClinical
                ? Value(i.allergies)
                : const Value.absent(),
            chronicConditions: includeClinical
                ? Value(i.chronicConditions)
                : const Value.absent(),
            updatedAt: Value(_now()),
          ),
        );
    if (n == 0) throw PatientRuleException('That patient no longer exists.');
  }

  /// Records a visit with whatever vitals were taken, and the clinician's
  /// notes if there are any.
  Future<void> recordVisit(
    int patientId, {
    required int userId,
    double? weightKg,
    int? bpSystolic,
    int? bpDiastolic,
    String? notes,
  }) async {
    if (weightKg != null && (weightKg <= 0 || weightKg > 400)) {
      throw PatientRuleException('Enter a weight between 1 and 400 kg.');
    }
    if ((bpSystolic == null) != (bpDiastolic == null)) {
      throw PatientRuleException(
        'Enter both blood pressure numbers, or neither.',
      );
    }
    if (bpSystolic != null &&
        (bpSystolic < 40 ||
            bpSystolic > 300 ||
            bpDiastolic! < 20 ||
            bpDiastolic > 200 ||
            bpDiastolic >= bpSystolic)) {
      throw PatientRuleException(
        'Check the blood pressure: the top number must be larger than the bottom.',
      );
    }
    final text = _clean(notes);
    if (weightKg == null && bpSystolic == null && text == null) {
      throw PatientRuleException(
        'Enter a weight, a blood pressure or a note to record the visit.',
      );
    }
    if (await get(patientId) == null) {
      throw PatientRuleException('That patient no longer exists.');
    }
    await _db.transaction(() async {
      final visitId = await _db
          .into(_db.visits)
          .insert(
            VisitsCompanion.insert(
              patientId: patientId,
              visitedAt: Value(_now()),
              weightKg: Value(weightKg),
              bpSystolic: Value(bpSystolic),
              bpDiastolic: Value(bpDiastolic),
              createdBy: userId,
            ),
          );
      if (text != null) {
        await _db
            .into(_db.consultations)
            .insert(
              ConsultationsCompanion.insert(
                visitId: visitId,
                clinicianId: userId,
                notes: text,
                createdAt: Value(_now()),
              ),
            );
      }
    });
  }
}

/// Age in whole years from a date of birth.
int ageFromDob(DateTime dob, DateTime now) {
  var years = now.year - dob.year;
  if (now.month < dob.month || (now.month == dob.month && now.day < dob.day)) {
    years--;
  }
  return years;
}

/// "34 years", "8 months" for babies, or "about 40 years"; null if unknown.
String? ageText(Patient p, DateTime now) {
  final dob = p.dateOfBirth;
  if (dob != null) {
    final y = ageFromDob(dob, now);
    if (y >= 2) return '$y years';
    final months =
        (now.year - dob.year) * 12 +
        now.month -
        dob.month -
        (now.day < dob.day ? 1 : 0);
    return months <= 0 ? 'under 1 month' : '$months months';
  }
  final a = p.approxAgeYears;
  return a == null ? null : 'about $a years';
}
