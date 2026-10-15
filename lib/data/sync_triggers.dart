/// Database triggers that queue every change to the data the dashboard shows.
///
/// Doing this in SQLite, not in each service, means a sale can never be saved
/// without being queued, whichever code path saved it. Each trigger writes one
/// `sync_outbox` row holding the row as JSON in the wire format described in
/// docs/dashboard/sync-api.md (snake_case server column names, UTC timestamps).
///
/// NEVER add patient data here: no patients, visits, consultations, no
/// `patient_id`/`visit_id`, no free-text notes, no PIN hashes or usernames.
library;

String _ts(String col) => "strftime('%Y-%m-%d %H:%M:%S', $col, 'unixepoch')";

// Dates are stored as the local midnight, so read them back in local time.
String _date(String col) =>
    "strftime('%Y-%m-%d', $col, 'unixepoch', 'localtime')";

class _Synced {
  const _Synced(this.entity, this.table, this.fields, {this.updateOf});

  /// Wire name, also the server table.
  final String entity;
  final String table;

  /// JSON key -> SQL expression over NEW.
  final Map<String, String> fields;

  /// When set, only these columns firing an UPDATE queue a change (used for
  /// `users`, whose PIN hash changes must not matter to the dashboard).
  final List<String>? updateOf;

  String get insertTrigger => 'sync_${table}_ai';
  String get updateTrigger => 'sync_${table}_au';

  String _body() {
    final json = fields.entries.map((e) => "'${e.key}', ${e.value}").join(', ');
    return 'INSERT INTO sync_outbox (entity, entity_id, payload_json, created_at) '
        "VALUES ('$entity', NEW.id, json_object($json), "
        "CAST(strftime('%s', 'now') AS INTEGER));";
  }

  String createInsert() =>
      'CREATE TRIGGER IF NOT EXISTS $insertTrigger AFTER INSERT ON $table '
      'BEGIN ${_body()} END';

  String createUpdate() {
    final of = updateOf == null ? '' : ' OF ${updateOf!.join(', ')}';
    return 'CREATE TRIGGER IF NOT EXISTS $updateTrigger AFTER UPDATE$of ON $table '
        'BEGIN ${_body()} END';
  }
}

/// In send order: a parent is always created before its children, so the
/// outbox (ordered by id) can be applied by the server in the order given.
final List<_Synced> _synced = [
  _Synced(
    'staff',
    'users',
    {
      'display_name': 'NEW.display_name',
      'role': 'NEW.role',
      'active': 'NEW.active',
    },
    updateOf: ['display_name', 'role', 'active'],
  ),
  _Synced('medicine', 'medicines', {
    'name': 'NEW.name',
    'generic_name': 'NEW.generic_name',
    'barcode': 'NEW.barcode',
    'base_unit_name': 'NEW.base_unit_name',
    'units_per_strip': 'NEW.units_per_strip',
    'units_per_pack': 'NEW.units_per_pack',
    'price_per_pack_cents': 'NEW.price_per_pack_cents',
    'price_per_strip_cents': 'NEW.price_per_strip_cents',
    'price_per_unit_cents': 'NEW.price_per_unit_cents',
    'low_stock_threshold': 'NEW.low_stock_threshold',
    'active': 'NEW.active',
    'updated_at': _ts('NEW.updated_at'),
  }),
  _Synced('batch', 'batches', {
    'medicine_local_id': 'NEW.medicine_id',
    'batch_number': 'NEW.batch_number',
    'expiry_date': _date('NEW.expiry_date'),
    'cost_per_unit_cents': 'NEW.cost_per_unit_cents',
    'created_at': _ts('NEW.created_at'),
  }),
  _Synced('sale', 'sales', {
    'receipt_no': 'NEW.receipt_no',
    'cashier_local_id': 'NEW.cashier_id',
    'status': 'NEW.status',
    'subtotal_cents': 'NEW.subtotal_cents',
    'discount_cents': 'NEW.discount_cents',
    'discount_authorised_by': 'NEW.discount_authorised_by',
    'total_cents': 'NEW.total_cents',
    'created_at': _ts('NEW.created_at'),
    'voided_at': _ts('NEW.voided_at'),
    'void_reason': 'NEW.void_reason',
  }),
  _Synced('sale_item', 'sale_items', {
    'sale_local_id': 'NEW.sale_id',
    'medicine_local_id': 'NEW.medicine_id',
    'batch_local_id': 'NEW.batch_id',
    'price_mode': 'NEW.price_mode',
    'qty_base_units': 'NEW.qty_base_units',
    'line_total_cents': 'NEW.line_total_cents',
  }),
  _Synced('payment', 'payments', {
    'sale_local_id': 'NEW.sale_id',
    'method': 'NEW.method',
    'amount_cents': 'NEW.amount_cents',
    'mpesa_code': 'NEW.mpesa_code',
    'created_at': _ts('NEW.created_at'),
  }),
  _Synced('stock_movement', 'stock_movements', {
    'batch_local_id': 'NEW.batch_id',
    'qty_delta': 'NEW.qty_delta',
    'reason': 'NEW.reason',
    'sale_local_id': 'NEW.sale_id',
    'created_by_local_id': 'NEW.created_by',
    'created_at': _ts('NEW.created_at'),
  }),
  _Synced('sale_return', 'sale_returns', {
    'sale_local_id': 'NEW.sale_id',
    'sale_item_local_id': 'NEW.sale_item_id',
    'qty_base_units': 'NEW.qty_base_units',
    'refund_cents': 'NEW.refund_cents',
    'refund_method': 'NEW.refund_method',
    'restocked': 'NEW.restocked',
    'reason': 'NEW.reason',
    'approved_by_local_id': 'NEW.approved_by',
    'created_at': _ts('NEW.created_at'),
  }),
];

/// `CREATE TRIGGER` statements for every synced table.
List<String> syncTriggerStatements() => [
  for (final s in _synced) ...[s.createInsert(), s.createUpdate()],
];

/// Statements that touch every existing row so the triggers queue it. Used
/// once, when sync is first switched on, to send what already exists.
/// Parents first, same order as the triggers above.
List<String> syncBackfillStatements() => [
  for (final s in _synced)
    // A no-op write still fires AFTER UPDATE triggers.
    'UPDATE ${s.table} SET ${s.updateOf?.first ?? 'id'} = ${s.updateOf?.first ?? 'id'}',
];
