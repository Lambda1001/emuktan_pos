import 'package:flutter/material.dart';

import '../../data/tables.dart';

enum Destination {
  sell('Sell', Icons.point_of_sale_outlined, Icons.point_of_sale),
  sales('Sales', Icons.receipt_long_outlined, Icons.receipt_long),
  patients('Patients', Icons.people_outline, Icons.people),
  stock('Stock', Icons.inventory_2_outlined, Icons.inventory_2),
  reports('Reports', Icons.bar_chart_outlined, Icons.bar_chart),
  settings('Staff and settings', Icons.settings_outlined, Icons.settings);

  const Destination(this.label, this.icon, this.selectedIcon);
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// Reports and settings are for the owner only (DESIGN.md section 3).
  bool visibleTo(Role role) => switch (this) {
    Destination.reports || Destination.settings => role == Role.owner,
    _ => true,
  };

  /// What the empty page tells the user, until the screen is built.
  String get comingSoon => switch (this) {
    Destination.sell => 'Sales will appear here.',
    Destination.sales => 'Past sales will appear here.',
    Destination.patients => 'Registered patients will appear here.',
    Destination.stock => 'Medicines and batches will appear here.',
    Destination.reports => 'Sales and stock reports will appear here.',
    Destination.settings =>
      'Staff accounts and shop settings will appear here.',
  };
}

List<Destination> destinationsFor(Role role) =>
    Destination.values.where((d) => d.visibleTo(role)).toList();

String roleLabel(Role role) => switch (role) {
  Role.owner => 'Owner',
  Role.clinician => 'Nurse / clinician',
  Role.cashier => 'Cashier',
};
