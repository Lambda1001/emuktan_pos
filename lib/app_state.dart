import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/bootstrap.dart';
import 'data/auth_service.dart';
import 'data/database.dart';
import 'data/sales_service.dart';
import 'data/stock_service.dart';

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
