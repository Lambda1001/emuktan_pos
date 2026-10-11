import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../data/sales_admin_service.dart';

/// Which sales to list: the last [days] days (0 means today), or those whose
/// receipt number contains [query] (which ignores the days).
typedef SalesQuery = ({int days, String query});

final salesListProvider = FutureProvider.autoDispose
    .family<List<SaleSummary>, SalesQuery>((ref, q) {
      final now = DateTime.now();
      final since = DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(Duration(days: q.days));
      return ref
          .watch(salesAdminServiceProvider)
          .recentSales(since: since, receiptQuery: q.query);
    });

final saleDetailProvider = FutureProvider.autoDispose.family<SaleDetail?, int>(
  (ref, id) => ref.watch(salesAdminServiceProvider).detail(id),
);
