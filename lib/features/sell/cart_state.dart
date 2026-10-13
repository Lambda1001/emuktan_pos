import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app_state.dart';
import '../../data/database.dart';
import '../../data/tables.dart';
import '../../domain/cart.dart';
import '../../domain/stock_rules.dart';

/// The open sale. Lives outside the screen so it survives switching tabs, and
/// it starts empty whenever a different person signs in.
class CartNotifier extends Notifier<List<CartLine>> {
  @override
  List<CartLine> build() {
    ref.watch(sessionProvider);
    return const [];
  }

  /// Smallest way of selling it, so a click never sells more than intended.
  static PriceMode defaultMode(Medicine m) {
    final modes = offeredModes(m);
    return modes.contains(PriceMode.unit) ? PriceMode.unit : modes.last;
  }

  /// Adds one more of [m] in its current mode, or a new line.
  void add(Medicine m) {
    final modes = offeredModes(m);
    if (modes.isEmpty) return;
    final i = state.indexWhere((l) => l.medicineId == m.id);
    if (i >= 0) {
      setCount(i, state[i].count + 1);
    } else {
      state = [
        ...state,
        CartLine(medicineId: m.id, mode: defaultMode(m), count: 1),
      ];
    }
  }

  void setCount(int index, int count) {
    if (count < 1) return;
    state = [...state]..[index] = state[index].copyWith(count: count);
  }

  void setMode(int index, PriceMode mode) {
    state = [...state]..[index] = state[index].copyWith(mode: mode);
  }

  void remove(int index) => state = [...state]..removeAt(index);

  void clear() => state = const [];

  /// Replaces the sale, for example when a parked sale is picked up.
  void load(List<CartLine> lines) => state = List.of(lines);
}

final cartProvider = NotifierProvider<CartNotifier, List<CartLine>>(
  CartNotifier.new,
);

/// Who the open sale is for, if anyone. Like the cart, it starts empty
/// whenever a different person signs in.
class CartPatientNotifier extends Notifier<Patient?> {
  @override
  Patient? build() {
    ref.watch(sessionProvider);
    return null;
  }

  void set(Patient? p) => state = p;
}

final cartPatientProvider = NotifierProvider<CartPatientNotifier, Patient?>(
  CartPatientNotifier.new,
);
