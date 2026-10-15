import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/bootstrap.dart';
import 'core/receipt_printer.dart';
import 'data/auth_service.dart';
import 'data/backup_service.dart';
import 'data/database.dart';
import 'data/held_sales_service.dart';
import 'data/patient_service.dart';
import 'data/report_service.dart';
import 'data/sales_admin_service.dart';
import 'data/sales_service.dart';
import 'data/stock_service.dart';
import 'data/sync_service.dart';

/// Holds the open database once startup finishes. Null only during startup,
/// when nothing that needs it is on screen yet.
class AppContextNotifier extends Notifier<AppContext?> {
  @override
  AppContext? build() => null;

  void set(AppContext app) => state = app;
}

final appContextProvider = NotifierProvider<AppContextNotifier, AppContext?>(
  AppContextNotifier.new,
);

final authServiceProvider = Provider<AuthService>(
  (ref) => AuthService(ref.watch(appContextProvider)!.db),
);

/// The signed-in user, or null when the app is locked / on the sign-in screen.
class SessionNotifier extends Notifier<User?> {
  @override
  User? build() => null;

  void signIn(User user) => state = user;
  void signOut() => state = null;
}

final sessionProvider = NotifierProvider<SessionNotifier, User?>(
  SessionNotifier.new,
);

/// Whether first-run owner setup is still needed. Auto-disposed so it is
/// re-read every time the app returns to the sign-in screen.
final hasUsersProvider = FutureProvider.autoDispose<bool>(
  (ref) => ref.watch(authServiceProvider).hasAnyUser(),
);

final stockServiceProvider = Provider<StockService>(
  (ref) => StockService(ref.watch(appContextProvider)!.db),
);

final salesServiceProvider = Provider<SalesService>(
  (ref) => SalesService(
    ref.watch(appContextProvider)!.db,
    ref.watch(stockServiceProvider),
  ),
);

final salesAdminServiceProvider = Provider<SalesAdminService>(
  (ref) => SalesAdminService(ref.watch(appContextProvider)!.db),
);

/// Null only when the app was opened without a database key (some tests).
final backupServiceProvider = Provider<BackupService?>((ref) {
  final app = ref.watch(appContextProvider);
  if (app == null || app.key == null) return null;
  return BackupService(app.db, app.dataDir, app.key!);
});

/// Last backup and any failure. Refresh with `ref.invalidate`.
final backupStatusProvider = FutureProvider<BackupStatus?>(
  (ref) => ref.watch(backupServiceProvider)?.status(),
);

/// How the app closes itself after a restore. Replaced in tests.
final appExitProvider = Provider<Future<void> Function()>((ref) {
  return () async {
    await ref.read(appContextProvider)?.db.close();
    exit(0);
  };
});

final heldSalesServiceProvider = Provider<HeldSalesService>(
  (ref) => HeldSalesService(ref.watch(appContextProvider)!.db),
);

/// Parked sales, oldest first. Refresh with `ref.invalidate` after any change.
final heldSalesProvider = FutureProvider<List<HeldSale>>(
  (ref) => ref.watch(heldSalesServiceProvider).list(),
);

final patientServiceProvider = Provider<PatientService>(
  (ref) => PatientService(ref.watch(appContextProvider)!.db),
);

final reportServiceProvider = Provider<ReportService>(
  (ref) => ReportService(
    ref.watch(appContextProvider)!.db,
    ref.watch(stockServiceProvider),
  ),
);

/// Where receipts print. A PDF for now; swap for the ESC/POS printer once the
/// thermal printer model is chosen (see `ReceiptPrinter`).
final receiptPrinterProvider = Provider<ReceiptPrinter>(
  (ref) => const PdfReceiptPrinter(),
);

final syncServiceProvider = Provider<SyncService?>((ref) {
  final app = ref.watch(appContextProvider);
  if (app == null) return null;
  return SyncService(app.db);
});

/// Queue size and last success. Refresh with `ref.invalidate`.
final syncStatusProvider = FutureProvider<SyncStatus?>(
  (ref) => ref.watch(syncServiceProvider)?.status(),
);
