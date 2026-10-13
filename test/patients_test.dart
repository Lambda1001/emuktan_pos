import 'package:drift/native.dart';
import 'package:emuktan_pos/core/format.dart';
import 'package:emuktan_pos/core/pin_hasher.dart';
import 'package:emuktan_pos/data/auth_service.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/patient_service.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late PatientService svc;
  late User clinician, cashier;
  final now = DateTime(2026, 10, 12, 9, 0);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    svc = PatientService(db, clock: () => now);
    final auth = AuthService(db, hasher: const PinHasher(iterations: 10));
    clinician = await auth.createUser(
      displayName: 'Nurse Achieng',
      role: Role.clinician,
      pin: '2468',
    );
    cashier = await auth.createUser(
      displayName: 'Jane Doe',
      role: Role.cashier,
      pin: '1357',
    );
  });
  tearDown(() => db.close());

  test('registers a patient and tidies what was typed', () async {
    final p = await svc.register(
      const PatientInput(
        fullName: '  Mary   Wambui ',
        phone: '0712 345-678',
        nationalId: ' ',
        approxAgeYears: 40,
      ),
      userId: cashier.id,
    );
    expect(p.fullName, 'Mary Wambui');
    expect(p.phone, '0712345678');
    expect(p.nationalId, isNull);
    expect(ageText(p, now), 'about 40 years');
  });

  test('rejects a missing name, a short phone and a future birth date', () {
    expect(
      svc.register(const PatientInput(fullName: ' '), userId: cashier.id),
      throwsA(isA<PatientRuleException>()),
    );
    expect(
      svc.register(
        const PatientInput(fullName: 'Ann', phone: '123'),
        userId: cashier.id,
      ),
      throwsA(isA<PatientRuleException>()),
    );
    expect(
      svc.register(
        PatientInput(fullName: 'Ann', dateOfBirth: DateTime(2027)),
        userId: cashier.id,
      ),
      throwsA(isA<PatientRuleException>()),
    );
  });

  test('an exact birth date replaces a guessed age', () async {
    final p = await svc.register(
      PatientInput(
        fullName: 'Peter Otieno',
        dateOfBirth: DateTime(1990, 10, 13),
        approxAgeYears: 99,
      ),
      userId: cashier.id,
    );
    expect(p.approxAgeYears, isNull);
    expect(ageText(p, now), '35 years'); // birthday is tomorrow
  });

  test('searches by name, phone and national id', () async {
    await svc.register(
      const PatientInput(
        fullName: 'Mary Wambui',
        phone: '0712345678',
        nationalId: '12345678',
      ),
      userId: cashier.id,
    );
    await svc.register(
      const PatientInput(fullName: 'John Kamau', phone: '0799000111'),
      userId: cashier.id,
    );
    expect((await svc.search('wambui')).single.fullName, 'Mary Wambui');
    expect((await svc.search('0712 345')).single.fullName, 'Mary Wambui');
    expect((await svc.search('1234567')).single.fullName, 'Mary Wambui');
    expect(await svc.search('zzz'), isEmpty);
    expect((await svc.search('')).first.fullName, 'John Kamau'); // newest
  });

  test('a cashier edit leaves the clinical notes alone', () async {
    final p = await svc.register(
      const PatientInput(fullName: 'Mary Wambui', allergies: 'Penicillin'),
      userId: clinician.id,
    );
    await svc.update(
      p.id,
      const PatientInput(fullName: 'Mary W. Njeri', allergies: ''),
      includeClinical: false,
    );
    final after = (await svc.get(p.id))!;
    expect(after.fullName, 'Mary W. Njeri');
    expect(after.allergies, 'Penicillin');

    await svc.update(
      p.id,
      const PatientInput(fullName: 'Mary W. Njeri', allergies: ''),
      includeClinical: true,
    );
    expect((await svc.get(p.id))!.allergies, isNull);
  });

  test('records visits with vitals and notes, newest first', () async {
    final p = await svc.register(
      const PatientInput(fullName: 'Mary Wambui'),
      userId: clinician.id,
    );
    await svc.recordVisit(
      p.id,
      userId: clinician.id,
      weightKg: 62.5,
      bpSystolic: 120,
      bpDiastolic: 80,
      notes: 'Mild headache.',
    );
    final visits = await svc.visits(p.id);
    expect(visits, hasLength(1));
    expect(visits.single.visit.weightKg, 62.5);
    expect(visits.single.notes.single.text, 'Mild headache.');
    expect(visits.single.notes.single.clinicianName, 'Nurse Achieng');
  });

  test('refuses an empty visit and impossible blood pressure', () async {
    final p = await svc.register(
      const PatientInput(fullName: 'Mary Wambui'),
      userId: clinician.id,
    );
    expect(
      svc.recordVisit(p.id, userId: clinician.id),
      throwsA(isA<PatientRuleException>()),
    );
    expect(
      svc.recordVisit(p.id, userId: clinician.id, bpSystolic: 80, bpDiastolic: 120),
      throwsA(isA<PatientRuleException>()),
    );
    expect(
      svc.recordVisit(p.id, userId: clinician.id, bpSystolic: 120),
      throwsA(isA<PatientRuleException>()),
    );
    expect(await svc.visits(p.id), isEmpty);
  });

  test('parseDate reads real dates only', () {
    expect(parseDate('07/10/1990'), DateTime(1990, 10, 7));
    expect(parseDate('7-1-2000'), DateTime(2000, 1, 7));
    expect(parseDate('31/02/2000'), isNull);
    expect(parseDate('nonsense'), isNull);
  });
}
