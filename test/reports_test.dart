import 'package:drift/native.dart';
import 'package:emuktan_pos/core/pin_hasher.dart';
import 'package:emuktan_pos/data/auth_service.dart';
import 'package:emuktan_pos/data/database.dart';
import 'package:emuktan_pos/data/report_service.dart';
import 'package:emuktan_pos/data/sales_admin_service.dart';
import 'package:emuktan_pos/data/sales_service.dart';
import 'package:emuktan_pos/data/stock_service.dart';
import 'package:emuktan_pos/data/tables.dart';
import 'package:emuktan_pos/domain/cart.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late AppDatabase db;
  late StockService stock;
  late SalesService sales;
  late SalesAdminService admin;
  late ReportService reports;
  late User owner, cashier;
  late int med;
  final now = DateTime(2026, 10, 10, 14, 32);
  final from = DateTime(2026, 10, 10);
  final to = DateTime(2026, 10, 11);

  const para = MedicineInput(
    name: 'Paracetamol 500mg',
    baseUnitName: 'tablet',
    unitsPerStrip: 10,
    pricePerStripCents: 9000,
    pricePerUnitCents: 1000,
    lowStockThreshold: 2000,
  );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final auth = AuthService(db, hasher: const PinHasher(iterations: 10));
    stock = StockService(db, clock: () => now);
    sales = SalesService(db, stock, clock: () => now);
    admin = SalesAdminService(db, clock: () => now);
    reports = ReportService(db, stock);
    owner = await auth.createUser(
      displayName: 'Wanjiru Kamau',
      role: Role.owner,
      pin: '4821',
    );
    cashier = await auth.createUser(
      displayName: 'Jane Doe',
      role: Role.cashier,
      pin: '1357',
    );
    med = await stock.createMedicine(para, userId: owner.id);
    await stock.receiveStock(
      medicineId: med,
      batchNumber: 'B1',
      expiry: DateTime(2028, 1, 31),
      qtyBaseUnits: 1000,
      costPerUnitCents: 500,
      userId: owner.id,
    );
  });
  tearDown(() => db.close());

  Future<int> idOf(SaleReceipt r) async =>
      (await (db.select(db.sales)..where((s) => s.receiptNo.equals(r.receiptNo))).getSingle()).id;

  test('an empty period reports nothing', () async {
    final r = await reports.sales(from: from, to: to);
    expect(r.isEmpty, isTrue);
    expect(r.netCents, 0);
  });

  test(
    'adds up sales, discounts, refunds, payment methods and best sellers',
    () async {
      // A: 3 strips, cash. B: 5 singles with a KES 5 discount, M-Pesa.
      final a = await sales.completeSale(
        lines: [CartLine(medicineId: med, mode: PriceMode.strip, count: 3)],
        cashierId: cashier.id,
        method: PaymentMethod.cash,
        cashTenderedCents: 30000,
      );
      await sales.completeSale(
        lines: [CartLine(medicineId: med, mode: PriceMode.unit, count: 5)],
        cashierId: cashier.id,
        discountCents: 500,
        discountApprovedBy: owner.id,
        method: PaymentMethod.mpesa,
        mpesaCode: 'SJK3H5T8LM',
      );
      // C is cancelled.
      final c = await sales.completeSale(
        lines: [CartLine(medicineId: med, mode: PriceMode.unit, count: 2)],
        cashierId: cashier.id,
        method: PaymentMethod.cash,
        cashTenderedCents: 2000,
      );
      await admin.voidSale(
        saleId: await idOf(c),
        reason: 'Wrong item',
        approverId: owner.id,
        actingUserId: owner.id,
      );
      // One strip of A comes back and is refunded in cash.
      final detail = (await admin.detail(await idOf(a)))!;
      await admin.returnItems(
        saleId: await idOf(a),
        qtyByItemId: {detail.lines.single.item.id: 10},
        reason: 'Changed mind',
        approverId: owner.id,
        actingUserId: owner.id,
        refundMethod: PaymentMethod.cash,
      );

      final r = await reports.sales(from: from, to: to);
      expect(r.salesCount, 2);
      expect(r.voidedCount, 1);
      expect(r.grossCents, 32000);
      expect(r.discountCents, 500);
      expect(r.refundCents, 9000);
      expect(r.netCents, 22500);
      expect(r.cashCents, 18000);
      expect(r.mpesaCents, 4500);
      expect(r.cashCents + r.mpesaCents, r.netCents);

      expect(r.topMedicines.single.qtyBaseUnits, 25);
      expect(r.topMedicines.single.revenueCents, 23000);
      expect(r.days.single.salesCount, 2);
      expect(r.cashiers.single.name, 'Jane Doe');

      // The day before sees none of it.
      final before = await reports.sales(
        from: DateTime(2026, 10, 9),
        to: DateTime(2026, 10, 10),
      );
      expect(before.isEmpty, isTrue);
    },
  );

  test('stock report values stock at cost and flags what is low', () async {
    var r = await reports.stock();
    expect(r.valueCents, 500000);
    expect(r.unpricedBatches, 0);

    await sales.completeSale(
      lines: [CartLine(medicineId: med, mode: PriceMode.strip, count: 50)],
      cashierId: cashier.id,
      method: PaymentMethod.cash,
      cashTenderedCents: 500000,
    );
    r = await reports.stock();
    expect(r.valueCents, 250000); // 500 tablets left at KES 5
    expect(r.low.single.medicine.id, med); // below the 2,000 level
  });

  test('the CSV carries the totals', () async {
    await sales.completeSale(
      lines: [CartLine(medicineId: med, mode: PriceMode.strip, count: 1)],
      cashierId: cashier.id,
      method: PaymentMethod.cash,
      cashTenderedCents: 9000,
    );
    final csv = ReportService.salesCsv(await reports.sales(from: from, to: to));
    expect(csv, contains('Net sales,90.00'));
    expect(csv, contains('2026-10-10,1,90.00'));
    expect(csv, contains('Paracetamol 500mg,10,tablet,90.00'));
  });
}
