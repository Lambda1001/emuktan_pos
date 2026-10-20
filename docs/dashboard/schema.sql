-- Emuktan web dashboard: server-side schema (HostAfrica, MySQL 8 / MariaDB 10.4+).
--
-- Read-only view of SALES and STOCK for the owner. By design it holds NO
-- patient data: no patients, visits, consultations, allergies, phone numbers
-- or patient ids. A sale arrives without its patient_id.
--
-- Rows are pushed from the clinic PC (see sync-protocol.md). Every synced
-- table is keyed by (clinic_id, local_id), where local_id is the primary key
-- the row has in the clinic's own SQLite database. That makes every push an
-- idempotent upsert: sending the same row twice changes nothing.
--
-- Conventions match the app: money is integer cents, stock is integer base
-- units, stock on hand is a SUM of movements and never a stored number.
-- Timestamps are UTC (DATETIME), converted to Africa/Nairobi when displayed.

SET NAMES utf8mb4;

-- ---------------------------------------------------------------- clinics --

-- One row per installed clinic PC. Phase 1 has exactly one.
CREATE TABLE clinic (
  id              SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT,
  name            VARCHAR(120)  NOT NULL,
  -- The PC authenticates with a long random key; only its SHA-256 is stored.
  api_key_hash    CHAR(64)      NOT NULL,
  app_version     VARCHAR(20)   NULL,
  last_sync_at    DATETIME      NULL,          -- last fully successful push
  created_at      DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_clinic_key (api_key_hash)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- One row per push, for support ("when did it last work, and what failed?")
-- and for the 24-hour "sync is stale" alert on the dashboard.
CREATE TABLE sync_log (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  clinic_id       SMALLINT UNSIGNED NOT NULL,
  received_at     DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  rows_received   INT UNSIGNED  NOT NULL DEFAULT 0,
  ok              TINYINT(1)    NOT NULL,
  error           VARCHAR(500)  NULL,
  PRIMARY KEY (id),
  KEY ix_sync_clinic_time (clinic_id, received_at),
  CONSTRAINT fk_sync_clinic FOREIGN KEY (clinic_id) REFERENCES clinic (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ------------------------------------------------------------------ staff --

-- Names and roles only, so sales can show who served. No PINs, hashes or
-- salts ever leave the clinic PC.
CREATE TABLE staff (
  clinic_id       SMALLINT UNSIGNED NOT NULL,
  local_id        INT UNSIGNED  NOT NULL,
  display_name    VARCHAR(120)  NOT NULL,
  role            ENUM('cashier','clinician','owner') NOT NULL,
  active          TINYINT(1)    NOT NULL DEFAULT 1,
  PRIMARY KEY (clinic_id, local_id),
  CONSTRAINT fk_staff_clinic FOREIGN KEY (clinic_id) REFERENCES clinic (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -------------------------------------------------------------- catalogue --

CREATE TABLE medicine (
  clinic_id             SMALLINT UNSIGNED NOT NULL,
  local_id              INT UNSIGNED  NOT NULL,
  name                  VARCHAR(200)  NOT NULL,
  generic_name          VARCHAR(200)  NULL,
  barcode               VARCHAR(64)   NULL,
  base_unit_name        VARCHAR(30)   NOT NULL DEFAULT 'unit',
  units_per_strip       INT UNSIGNED  NULL,
  units_per_pack        INT UNSIGNED  NULL,
  price_per_pack_cents  INT UNSIGNED  NULL,
  price_per_strip_cents INT UNSIGNED  NULL,
  price_per_unit_cents  INT UNSIGNED  NULL,
  low_stock_threshold   INT UNSIGNED  NOT NULL DEFAULT 0,   -- base units
  active                TINYINT(1)    NOT NULL DEFAULT 1,
  updated_at            DATETIME      NOT NULL,
  PRIMARY KEY (clinic_id, local_id),
  KEY ix_medicine_name (clinic_id, name),
  CONSTRAINT fk_medicine_clinic FOREIGN KEY (clinic_id) REFERENCES clinic (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE batch (
  clinic_id             SMALLINT UNSIGNED NOT NULL,
  local_id              INT UNSIGNED  NOT NULL,
  medicine_local_id     INT UNSIGNED  NOT NULL,
  batch_number          VARCHAR(60)   NOT NULL,
  expiry_date           DATE          NULL,
  cost_per_unit_cents   INT UNSIGNED  NULL,    -- NULL = not entered yet
  created_at            DATETIME      NOT NULL,
  PRIMARY KEY (clinic_id, local_id),
  KEY ix_batch_medicine (clinic_id, medicine_local_id),
  KEY ix_batch_expiry (clinic_id, expiry_date),
  CONSTRAINT fk_batch_medicine FOREIGN KEY (clinic_id, medicine_local_id)
    REFERENCES medicine (clinic_id, local_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- The stock ledger. Positive adds stock, negative removes it.
CREATE TABLE stock_movement (
  clinic_id             SMALLINT UNSIGNED NOT NULL,
  local_id              INT UNSIGNED  NOT NULL,
  batch_local_id        INT UNSIGNED  NOT NULL,
  qty_delta             INT           NOT NULL,     -- base units
  reason                VARCHAR(30)   NOT NULL,     -- the app's MovementReason name
  sale_local_id         INT UNSIGNED  NULL,
  created_by_local_id   INT UNSIGNED  NOT NULL,
  created_at            DATETIME      NOT NULL,
  PRIMARY KEY (clinic_id, local_id),
  KEY ix_move_batch (clinic_id, batch_local_id),
  KEY ix_move_time (clinic_id, created_at),
  CONSTRAINT fk_move_batch FOREIGN KEY (clinic_id, batch_local_id)
    REFERENCES batch (clinic_id, local_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
-- The app's free-text stock "note" is not synced: it can name a patient.

-- ------------------------------------------------------------------ sales --

CREATE TABLE sale (
  clinic_id             SMALLINT UNSIGNED NOT NULL,
  local_id              INT UNSIGNED  NOT NULL,
  receipt_no            VARCHAR(30)   NOT NULL,
  cashier_local_id      INT UNSIGNED  NOT NULL,
  status                ENUM('completed','voided') NOT NULL,
  subtotal_cents        INT UNSIGNED  NOT NULL,
  discount_cents        INT UNSIGNED  NOT NULL DEFAULT 0,
  discount_authorised_by INT UNSIGNED NULL,
  total_cents           INT UNSIGNED  NOT NULL,
  created_at            DATETIME      NOT NULL,
  voided_at             DATETIME      NULL,
  void_reason           VARCHAR(300)  NULL,
  -- patient_id / visit_id are deliberately absent.
  PRIMARY KEY (clinic_id, local_id),
  UNIQUE KEY uq_sale_receipt (clinic_id, receipt_no),
  KEY ix_sale_time (clinic_id, created_at),
  CONSTRAINT fk_sale_clinic FOREIGN KEY (clinic_id) REFERENCES clinic (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE sale_item (
  clinic_id             SMALLINT UNSIGNED NOT NULL,
  local_id              INT UNSIGNED  NOT NULL,
  sale_local_id         INT UNSIGNED  NOT NULL,
  medicine_local_id     INT UNSIGNED  NOT NULL,
  batch_local_id        INT UNSIGNED  NOT NULL,
  price_mode            ENUM('pack','strip','unit') NOT NULL,
  qty_base_units        INT UNSIGNED  NOT NULL,
  line_total_cents      INT UNSIGNED  NOT NULL,
  PRIMARY KEY (clinic_id, local_id),
  KEY ix_item_sale (clinic_id, sale_local_id),
  KEY ix_item_medicine (clinic_id, medicine_local_id),
  CONSTRAINT fk_item_sale FOREIGN KEY (clinic_id, sale_local_id)
    REFERENCES sale (clinic_id, local_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE payment (
  clinic_id             SMALLINT UNSIGNED NOT NULL,
  local_id              INT UNSIGNED  NOT NULL,
  sale_local_id         INT UNSIGNED  NOT NULL,
  method                ENUM('cash','mpesa') NOT NULL,
  amount_cents          INT UNSIGNED  NOT NULL,
  mpesa_code            VARCHAR(20)   NULL,         -- a transaction id, not a phone number
  created_at            DATETIME      NOT NULL,
  PRIMARY KEY (clinic_id, local_id),
  KEY ix_pay_sale (clinic_id, sale_local_id),
  KEY ix_pay_time (clinic_id, created_at),
  CONSTRAINT fk_pay_sale FOREIGN KEY (clinic_id, sale_local_id)
    REFERENCES sale (clinic_id, local_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE sale_return (
  clinic_id             SMALLINT UNSIGNED NOT NULL,
  local_id              INT UNSIGNED  NOT NULL,
  sale_local_id         INT UNSIGNED  NOT NULL,
  sale_item_local_id    INT UNSIGNED  NOT NULL,
  qty_base_units        INT UNSIGNED  NOT NULL,
  refund_cents          INT UNSIGNED  NOT NULL,
  refund_method         ENUM('cash','mpesa') NOT NULL,
  restocked             TINYINT(1)    NOT NULL,
  reason                VARCHAR(300)  NOT NULL,
  approved_by_local_id  INT UNSIGNED  NOT NULL,
  created_at            DATETIME      NOT NULL,
  PRIMARY KEY (clinic_id, local_id),
  KEY ix_return_time (clinic_id, created_at),
  CONSTRAINT fk_return_sale FOREIGN KEY (clinic_id, sale_local_id)
    REFERENCES sale (clinic_id, local_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- -------------------------------------------------------- dashboard logins --

CREATE TABLE dash_user (
  id              INT UNSIGNED  NOT NULL AUTO_INCREMENT,
  clinic_id       SMALLINT UNSIGNED NOT NULL,
  email           VARCHAR(190)  NOT NULL,
  display_name    VARCHAR(120)  NOT NULL,
  -- owner: everything, including managing logins. manager: everything
  -- except managing logins. viewer: sales and stock, no cost or profit.
  role            ENUM('owner','manager','viewer') NOT NULL DEFAULT 'viewer',
  password_hash   VARCHAR(255)  NOT NULL,          -- PHP password_hash(), argon2id or bcrypt
  totp_secret     VARCHAR(64)   NULL,              -- set when two-step sign-in is enabled
  active          TINYINT(1)    NOT NULL DEFAULT 1,
  failed_logins   TINYINT UNSIGNED NOT NULL DEFAULT 0,
  locked_until    DATETIME      NULL,
  last_login_at   DATETIME      NULL,
  created_at      DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY uq_dash_email (email),
  CONSTRAINT fk_dash_clinic FOREIGN KEY (clinic_id) REFERENCES clinic (id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- Every sign-in attempt, for lockout and for "who looked at this, and when".
CREATE TABLE dash_login_log (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  email           VARCHAR(190)  NOT NULL,
  ip              VARCHAR(45)   NOT NULL,
  ok              TINYINT(1)    NOT NULL,
  at              DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_login_email_time (email, at),
  KEY ix_login_ip_time (ip, at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- ------------------------------------------------------------------ views --
-- The dashboard pages read these, so the arithmetic lives in one place.

-- Stock on hand per batch: the ledger summed, hiding empty batches.
CREATE VIEW v_batch_stock AS
SELECT b.clinic_id, b.local_id AS batch_local_id, b.medicine_local_id,
       b.batch_number, b.expiry_date, b.cost_per_unit_cents,
       SUM(m.qty_delta) AS on_hand
FROM batch b
JOIN stock_movement m
  ON m.clinic_id = b.clinic_id AND m.batch_local_id = b.local_id
GROUP BY b.clinic_id, b.local_id, b.medicine_local_id,
         b.batch_number, b.expiry_date, b.cost_per_unit_cents
HAVING SUM(m.qty_delta) <> 0;

-- Stock on hand per medicine, with the low-stock flag and value at cost.
-- Value ignores batches with no cost entered (the page says how many).
CREATE VIEW v_medicine_stock AS
SELECT md.clinic_id, md.local_id AS medicine_local_id, md.name,
       md.base_unit_name, md.low_stock_threshold,
       COALESCE(SUM(bs.on_hand), 0) AS on_hand,
       COALESCE(SUM(bs.on_hand * bs.cost_per_unit_cents), 0) AS value_cents,
       SUM(bs.cost_per_unit_cents IS NULL) AS unpriced_batches,
       MIN(CASE WHEN bs.on_hand > 0 THEN bs.expiry_date END) AS next_expiry
FROM medicine md
LEFT JOIN v_batch_stock bs
  ON bs.clinic_id = md.clinic_id AND bs.medicine_local_id = md.local_id
WHERE md.active = 1
GROUP BY md.clinic_id, md.local_id, md.name, md.base_unit_name, md.low_stock_threshold;

-- Completed sales per local (Nairobi) day, split by how they were paid.
-- Net of refunds is computed in the app layer from sale_return by day.
CREATE VIEW v_daily_sales AS
SELECT s.clinic_id,
       DATE(CONVERT_TZ(s.created_at, '+00:00', '+03:00')) AS day,
       COUNT(*)                         AS sales_count,
       SUM(s.subtotal_cents)            AS gross_cents,
       SUM(s.discount_cents)            AS discount_cents,
       SUM(s.total_cents)               AS total_cents
FROM sale s
WHERE s.status = 'completed'
GROUP BY s.clinic_id, DATE(CONVERT_TZ(s.created_at, '+00:00', '+03:00'));
-- Profit per sale line: what was charged, less the batch's cost for the
-- units sold. cost_cents is NULL when the batch has no cost entered, so the
-- page can say how many lines are excluded instead of showing a wrong profit.
-- Returns are subtracted in the app layer from sale_return (refund_cents),
-- and restocked units come back at cost.
CREATE VIEW v_sale_item_profit AS
SELECT i.clinic_id, i.sale_local_id, i.medicine_local_id,
       DATE(CONVERT_TZ(s.created_at, '+00:00', '+03:00')) AS day,
       i.qty_base_units, i.line_total_cents,
       i.qty_base_units * b.cost_per_unit_cents AS cost_cents
FROM sale_item i
JOIN sale  s ON s.clinic_id = i.clinic_id AND s.local_id = i.sale_local_id
JOIN batch b ON b.clinic_id = i.clinic_id AND b.local_id = i.batch_local_id
WHERE s.status = 'completed';

-- East Africa Time is a fixed UTC+3 with no daylight saving, so a literal
-- offset is safe and does not depend on the host's timezone tables.
