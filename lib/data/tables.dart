import 'package:drift/drift.dart';

// Conventions
//  * Money is stored as integer cents (KES x 100). Never use doubles for money.
//  * Stock is stored in the medicine's smallest "base unit" (e.g. one tablet),
//    so strip/pack pricing is a conversion and partial dispensing is exact.
//  * Stock on hand is never stored: it is SUM(qty_delta) over StockMovements.
//  * Every business record carries created_by / created_at so the Phase 1.5
//    audit log can be built on top without reworking the schema.

enum Role { cashier, clinician, owner }

enum Sex { female, male, other }

enum SaleStatus { completed, voided }

enum PaymentMethod { cash, mpesa }

enum PriceMode { pack, strip, unit }

enum MovementReason {
  receipt,
  sale,
  saleVoid,
  saleReturn,
  adjustment,
  writeOffExpired,
  writeOffDamaged,
}

class Users extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get username => text().withLength(min: 2, max: 40).unique()();
  TextColumn get displayName => text()();
  TextColumn get role => textEnum<Role>()();
  // Salted hash of the PIN/password, never the secret itself.
  TextColumn get secretHash => text()();
  TextColumn get secretSalt => text()();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class Patients extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get fullName => text()();
  TextColumn get phone => text().nullable()();
  TextColumn get nationalId => text().nullable()();
  DateTimeColumn get dateOfBirth => dateTime().nullable()();
  IntColumn get approxAgeYears => integer().nullable()();
  TextColumn get sex => textEnum<Sex>().nullable()();
  // Phase 1: free text. Structured fields and warnings are Phase 1.5.
  TextColumn get allergies => text().nullable()();
  TextColumn get chronicConditions => text().nullable()();
  IntColumn get createdBy => integer().references(Users, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

class Visits extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get patientId => integer().references(Patients, #id)();
  DateTimeColumn get visitedAt => dateTime().withDefault(currentDateAndTime)();
  // Vitals are per visit; the "profile" shows the latest values.
  RealColumn get weightKg => real().nullable()();
  IntColumn get bpSystolic => integer().nullable()();
  IntColumn get bpDiastolic => integer().nullable()();
  IntColumn get createdBy => integer().references(Users, #id)();
}

class Consultations extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get visitId => integer().references(Visits, #id)();
  IntColumn get clinicianId => integer().references(Users, #id)();
  TextColumn get notes => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class Medicines extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get genericName => text().nullable()();
  TextColumn get barcode => text().nullable().unique()();
  // Name of the smallest dispensable unit: "tablet", "ml", "sachet".
  TextColumn get baseUnitName => text().withDefault(const Constant('unit'))();
  // Conversion factors; null means that way of selling is not offered.
  IntColumn get unitsPerStrip => integer().nullable()();
  IntColumn get unitsPerPack => integer().nullable()();
  // Prices in cents for each way of selling; null = not offered.
  IntColumn get pricePerPackCents => integer().nullable()();
  IntColumn get pricePerStripCents => integer().nullable()();
  IntColumn get pricePerUnitCents => integer().nullable()();
  // Low-stock alert threshold, in base units.
  IntColumn get lowStockThreshold => integer().withDefault(const Constant(0))();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
  IntColumn get createdBy => integer().references(Users, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}

@DataClassName('Batch')
class Batches extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get medicineId => integer().references(Medicines, #id)();
  TextColumn get batchNumber => text()();
  DateTimeColumn get expiryDate => dateTime().nullable()();
  // Cost per base unit in cents (may be fractional-cent accurate only to 1c).
  IntColumn get costPerUnitCents => integer().nullable()();
  TextColumn get supplierNote => text().nullable()();
  IntColumn get createdBy => integer().references(Users, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  List<Set<Column>> get uniqueKeys => [
    {medicineId, batchNumber},
  ];
}

class StockMovements extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get batchId => integer().references(Batches, #id)();
  // Positive adds stock, negative removes it. Base units.
  IntColumn get qtyDelta => integer()();
  TextColumn get reason => textEnum<MovementReason>()();
  IntColumn get saleId => integer().nullable().references(Sales, #id)();
  TextColumn get note => text().nullable()();
  IntColumn get createdBy => integer().references(Users, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class Sales extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get receiptNo => text().unique()();
  IntColumn get patientId => integer().nullable().references(Patients, #id)();
  IntColumn get visitId => integer().nullable().references(Visits, #id)();
  IntColumn get cashierId => integer().references(Users, #id)();
  TextColumn get status =>
      textEnum<SaleStatus>().withDefault(const Constant('completed'))();
  IntColumn get subtotalCents => integer()();
  IntColumn get discountCents => integer().withDefault(const Constant(0))();
  // Discounts need a clinician/owner; record who approved.
  IntColumn get discountAuthorisedBy =>
      integer().nullable().references(Users, #id)();
  IntColumn get totalCents => integer()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get voidedAt => dateTime().nullable()();
  IntColumn get voidedBy => integer().nullable().references(Users, #id)();
  TextColumn get voidReason => text().nullable()();
}

class SaleItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get saleId => integer().references(Sales, #id)();
  IntColumn get medicineId => integer().references(Medicines, #id)();
  IntColumn get batchId => integer().references(Batches, #id)();
  TextColumn get priceMode => textEnum<PriceMode>()();
  // Quantity sold in base units, plus the price actually charged.
  IntColumn get qtyBaseUnits => integer()();
  IntColumn get lineTotalCents => integer()();
}

class Payments extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get saleId => integer().references(Sales, #id)();
  TextColumn get method => textEnum<PaymentMethod>()();
  IntColumn get amountCents => integer()();
  // M-Pesa transaction code, entered manually in Phase 1.
  TextColumn get mpesaCode => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

class ClockEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get userId => integer().references(Users, #id)();
  DateTimeColumn get clockIn => dateTime()();
  DateTimeColumn get clockOut => dateTime().nullable()();
}

class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

/// Changes waiting to be pushed to the hosted dashboard (Phase 1, P1-16).
class SyncOutbox extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get entity => text()();
  IntColumn get entityId => integer()();
  TextColumn get payloadJson => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get sentAt => dateTime().nullable()();
}

/// Items handed back after a sale. A voided sale is cancelled whole (see
/// Sales.status); a return takes some units of some lines back and refunds
/// what was actually paid for them.
class SaleReturns extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get saleId => integer().references(Sales, #id)();
  IntColumn get saleItemId => integer().references(SaleItems, #id)();
  // Base units handed back.
  IntColumn get qtyBaseUnits => integer()();
  // What was given back for these units, after any discount share.
  IntColumn get refundCents => integer()();
  TextColumn get refundMethod => textEnum<PaymentMethod>()();
  // False when the medicine cannot be resold (damaged, opened): stock is not added back.
  BoolColumn get restocked => boolean().withDefault(const Constant(true))();
  TextColumn get reason => text()();
  // The owner or clinician who approved it.
  IntColumn get approvedBy => integer().references(Users, #id)();
  IntColumn get createdBy => integer().references(Users, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// A sale set aside before payment, so the customer can come back to it.
/// Holds no stock: quantities and prices are checked again when it is resumed.
@DataClassName('HeldSaleRow')
class HeldSales extends Table {
  IntColumn get id => integer().autoIncrement()();
  // What the cashier typed to recognise it, for example a customer's name.
  TextColumn get label => text().nullable()();
  // The cart as JSON: [{"m": medicineId, "mode": "strip", "n": 3}, ...]
  TextColumn get linesJson => text()();
  IntColumn get discountCents => integer().withDefault(const Constant(0))();
  // Who approved the discount (owner or clinician), if there is one.
  IntColumn get discountApprovedBy =>
      integer().nullable().references(Users, #id)();
  IntColumn get parkedBy => integer().references(Users, #id)();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
