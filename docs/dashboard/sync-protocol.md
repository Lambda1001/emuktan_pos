# Dashboard sync protocol (P1-16, P1-18)

Status: proposal. The server schema is `schema.sql` (loads and the views compute correctly on MariaDB 10.4; tested with sample rows).

## Two separate jobs

The tracker lumps these together as "backup/sync". They have different needs, so build them as two channels:

| | Offsite backup | Dashboard feed |
|---|---|---|
| Purpose | Recover the clinic if the PC dies | Owner sees sales and stock from a phone |
| Content | Whole encrypted database (`VACUUM INTO` snapshot) | Sales and stock rows only, readable |
| Patient data | Included, but encrypted. The server cannot read it | Never leaves the clinic |
| Server stores | A file | MySQL rows (`schema.sql`) |
| Needs the key | Yes, to restore | No |

An encrypted snapshot cannot feed a dashboard, because the server has no key and must not get one. So the dashboard feed is a second, small push of plain rows.

## Dashboard feed

**Transport.** HTTPS `POST /api/sync` with `Authorization: Bearer <clinic key>`. The key is 32 random bytes, created when the clinic is registered on the server and typed into Settings on the clinic PC once. The server stores only its SHA-256 (`clinic.api_key_hash`). On the PC the key is stored in the `settings` table of the SQLCipher-encrypted database, so it is protected by the same key as everything else.

**What is sent.** The existing `SyncOutbox` table (`entity`, `entityId`, `payloadJson`, `sentAt`) is the queue. Each row is one record that changed. Entities, in send order, so parents arrive before children:

`staff, medicine, batch, sale, sale_item, payment, stock_movement, sale_return`

The payload is the row with the same column names as the server table, minus anything on this list, which is never sent:

- `sales.patient_id`, `sales.visit_id`
- `stock_movements.note` (free text can name a patient)
- anything from `patients`, `visits`, `consultations`
- `users.secret_hash`, `users.secret_salt`

**Idempotent.** The server upserts on `(clinic_id, local_id)`, so a retry after a dropped connection never double-counts. The clinic marks `sentAt` only after the server answers `200`.

**Batching.** Up to 500 rows per request, oldest first. The response is `{"accepted": N}`; any error leaves the rest queued.

**When.** On an interval (every 5 minutes while online) and once when the app closes. Not "nightly", because the clinic PC may be off at night. A failed push is silent: no dialog, the status bar says "Working offline". If nothing has succeeded for 24 hours the status bar turns amber (DESIGN.md rule 7).

**Writing to the outbox.** Every service that inserts or updates a synced table also inserts a `SyncOutbox` row in the same transaction, so a sale can never be saved without being queued. (Not built yet: the table exists and nothing writes to it.)

**First sync.** On first connect, enqueue everything that already exists in the synced tables.

## Offsite backup

Reuse `AppDatabase.backupTo` (already encrypted and tested), then upload the file to `/api/backup` with the same key. The server keeps the newest 14 snapshots. The backup is useless without the recovery key, which the owner holds (README, "Encryption design").

## Dashboard security

Public internet, so:

- HTTPS only, HSTS, redirect HTTP.
- Passwords with `password_hash()`; five failures lock the account for 15 minutes (`dash_user.failed_logins`, `locked_until`); every attempt logged in `dash_login_log`.
- Two-step sign-in (TOTP) available per user (`totp_secret`). Recommended on for the owner.
- Session cookie `Secure; HttpOnly; SameSite=Strict`. Sessions time out after 30 minutes idle.
- Prepared statements only. The dashboard database user has `SELECT` on the dashboard tables; the sync endpoint uses a second user with `INSERT/UPDATE` and no `DELETE`.
- No patient data exists on the server, so a breach of the dashboard cannot expose it.

## Decisions (15 Oct 2026)

1. **Hosting.** HostAfrica plan includes PHP and MySQL/MariaDB.
2. **Logins.** The owner plus anyone else who needs it. `dash_user.role`: owner (manages logins), manager, viewer (sales and stock, no cost or profit).
3. **Cost and profit are included.** `batch.cost_per_unit_cents` is synced and `v_sale_item_profit` computes profit. Because cost prices sit on a public site, two-step sign-in (TOTP) should be required for owner and manager, and the cost endpoints must check the role on the server, not just hide the panel.

## Open: card/M-Pesa integration (KCB Buni)

A HostAfrica domain can serve as the public HTTPS callback URL, but it changes the design. See the notes in the project chat; summary: the server would receive payment confirmations, so the clinic PC must fetch them (poll) rather than only push, and it needs its own table and a Change Request, since STK push is outside Phase 1.
