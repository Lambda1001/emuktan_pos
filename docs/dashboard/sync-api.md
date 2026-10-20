# Sync API contract (clinic PC to dashboard server)

Both sides are built to this file. Server tables are in `schema.sql` (the Laravel app in `D:\Work\Emuktan\dashboard` implements them as migrations). Background and security rules: `sync-protocol.md`.

All endpoints are HTTPS, under `/api`, and need `Authorization: Bearer <clinic key>`. The server compares SHA-256(key) with `clinic.api_key_hash`. Responses are JSON.

## GET /api/ping

Cheap check used by the app's "Test connection" button.

`200 {"ok": true, "clinic": "<clinic name>", "server_time": "2026-10-15 19:04:55", "features": {"mpesa_stk": false}}` (UTC). `features` is additive: `mpesa_stk` is true when the dashboard can send M-Pesa prompts (see below). The same `features` object is returned by `POST /api/sync`; the app remembers the last answer.
`401 {"error": "unauthorised"}` for a missing or wrong key.

## POST /api/sync

```json
{
  "app_version": "1.0.0",
  "rows": [
    {"entity": "staff",          "local_id": 1,  "data": {"display_name": "Jane Doe", "role": "cashier", "active": 1}},
    {"entity": "medicine",       "local_id": 7,  "data": {"name": "Amoxicillin 500mg", "...": "..."}},
    {"entity": "sale",           "local_id": 42, "data": {"receipt_no": "R20261015-0001", "...": "..."}}
  ]
}
```

- `entity` is one of `staff, medicine, batch, stock_movement, sale, sale_item, payment, sale_return`; each maps to the server table of the same name.
- `local_id` is the row's primary key in the clinic's SQLite database. The server key is `(clinic_id, local_id)`; `clinic_id` comes from the bearer key, never from the body.
- `data` holds the table's other columns, **named exactly as in `schema.sql`** (snake_case). Foreign keys use the `*_local_id` columns. Server-only columns are never sent.
- Formats: money in integer cents; stock in integer base units; booleans `0`/`1`; timestamps `"YYYY-MM-DD HH:MM:SS"` in **UTC**; dates (`batch.expiry_date`) `"YYYY-MM-DD"`; unknown or missing optional values are JSON `null`.
- Rows arrive in the order they changed. A parent is always created before its children, so rows can be applied in the order given, in one database transaction.
- **Upsert, last write wins.** A row already on the server is overwritten with the new values. Sending a row twice changes nothing. The same `(entity, local_id)` may appear several times in one request (several edits); apply them in order.
- At most 500 rows per request. **An empty `rows` array is valid** and counts as a check-in: the app sends it when nothing is queued, so the server can tell "clinic quiet" from "PC off". It updates `clinic.last_sync_at` like any other `200`.

Responses:

- `200 {"accepted": 500}`: every row was applied. The app then marks them sent.
- `401`: bad key.
- `422 {"error": "<message>", "index": 17}`: row `index` (0-based) is invalid or its parent is missing. Nothing in the request was applied (single transaction). The app keeps the rows queued and reports the error.
- `5xx` or no answer: treat as offline; retry later.

On a `200` (including an empty check-in) the server sets `clinic.last_sync_at` and `clinic.app_version`. Every call, failed or not, writes a `sync_log` row. A failed call leaves `last_sync_at` alone, so the dashboard's 24-hour "not synced" banner means what it says.

### Never sent

`patients`, `visits`, `consultations`, `held_sales`, `users.secret_hash`, `users.secret_salt`, `users.username`, `sales.patient_id`, `sales.visit_id`, `stock_movements.note`, `batches.supplier_note`.

### Per-entity fields

| entity | data fields |
|---|---|
| staff | display_name, role (`cashier`/`clinician`/`owner`), active |
| medicine | name, generic_name, barcode, base_unit_name, units_per_strip, units_per_pack, price_per_pack_cents, price_per_strip_cents, price_per_unit_cents, low_stock_threshold, active, updated_at |
| batch | medicine_local_id, batch_number, expiry_date, cost_per_unit_cents, created_at |
| stock_movement | batch_local_id, qty_delta, reason, sale_local_id, created_by_local_id, created_at |
| sale | receipt_no, cashier_local_id, status (`completed`/`voided`), subtotal_cents, discount_cents, discount_authorised_by, total_cents, created_at, voided_at, void_reason |
| sale_item | sale_local_id, medicine_local_id, batch_local_id, price_mode, qty_base_units, line_total_cents |
| payment | sale_local_id, method (`cash`/`mpesa`), amount_cents, mpesa_code, created_at |
| sale_return | sale_local_id, sale_item_local_id, qty_base_units, refund_cents, refund_method, restocked, reason, approved_by_local_id, created_at |

## POST /api/backup

Body is the raw bytes of an encrypted database snapshot (`Content-Type: application/octet-stream`). The server stores it as `backups/<clinic_id>/<UTC timestamp>.db`, keeps the newest 14, and answers `200 {"stored": "<filename>", "bytes": N}`. It never opens the file. The app sends the newest backup after each local backup and retries until the server's `bytes` equals the file size.

## M-Pesa prompts (STK push through KCB Buni)

Out of Phase 1 (a Change Request). The dashboard holds the KCB credentials and receives KCB's callback; the clinic PC only asks and polls, so no payment secret is stored on the PC. If `features.mpesa_stk` is false the app does not offer the option and the cashier types the M-Pesa code as before.

### POST /api/mpesa/stk

```json
{"request_id": "<uuid v4 chosen by the app>", "amount_cents": 150000, "phone": "0712 345 678", "reference": "R20261020-0001"}
```

- `request_id` makes a retry safe: the same id returns the existing request (200) and never sends a second prompt. The same id with a different amount is `409`.
- `amount_cents` must be a whole number of shillings (M-Pesa takes no cents), at most the M-Pesa limit; otherwise `422`.
- `phone` is normalised (`07…`, `01…`, `+254…`, `254…`); anything else is `422 {"error": "That is not a Safaricom phone number."}`.
- At most 5 prompts pending per clinic in 5 minutes (`429`).
- `501` when the dashboard has prompts switched off.

`202` for a new request, `200` for a repeat: `{"request_id", "status", "amount_cents", "phone": "254712***678", "receipt": null, "message": null}`. The full number is held only while the request is pending, then dropped.

### GET /api/mpesa/stk/{request_id}

Same body. `status` is one of `pending`, `success` (then `receipt` is the real M-Pesa code), `failed`, `cancelled`, `timeout` (no answer after 120 s; a late payment still turns it into `success`), `review`. **`review` is never paid**: the result did not match the request (checkout id, amount, malformed or already-used receipt) and the statement must be checked. Poll every few seconds.

### POST /api/buni/stk/{secret} (KCB, not the app)

KCB's STK callback carries no signature, so the request is identified by a one-time 40-hex secret in the URL (only its SHA-256 is stored) and checked against what was asked. Unknown secrets get a bare `404`; every known one gets `{"ResultCode": 0, "ResultDesc": "Accepted"}`; the first final answer stands.

The dashboard's Day close page marks an M-Pesa payment **Confirmed** when its code matches a successful prompt for the same amount, otherwise **Typed by hand**.
