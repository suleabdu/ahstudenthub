# Cashbook compatibility API

`cashbook-api` is the migration boundary between the existing Owner/Sales Rep
PWAs and Supabase. It deliberately retains the current request envelope and
response shape:

```json
{ "action": "sync", "token": "<access token>", "entries": [] }
```

```json
{ "ok": true, "data": { "results": [], "snapshot": {} } }
```

It is **not** a second accounting engine. Financial mutations call PostgreSQL
RPCs, where inventory locking, FIFO allocation, ledger writes, audit logging,
and idempotency happen in one transaction.

## Current migration coverage

- Native Supabase Auth login using the existing username/PIN screen.
- `snapshot`, `refresh`, `dashboard`, owner reads, product/catalogue reads,
  party statements, stock cards, reports, attention inboxes and audit reads.
- Reviewed `previewProducts` / `importProducts` and opening-stock preview/import.
- Sales, purchasing/stock-in, expenses, customer/supplier payments, returns,
  owner money, stock adjustments, transfers, opening balances and reversals
  posted through `entry` or `sync` database commands.
- Owner product, party, location, settings, period-close and attention updates.
- Owner-created staff accounts, secure PIN resets, staff product requests,
  approved Chairman/CEO WhatsApp recipients, and read-only integrity/reset
  preview support once migration `20261115190700_production_operations.sql`
  is applied.
- Private product-image storage, signed owner-library URLs, and catalogue
  matching by SKU/barcode, saved-image fingerprint, and catalogue text. It
  deliberately does **not** claim external AI labels until an approved vision
  provider and secret are separately deployed.
- Existing queue response shapes, including `clientId`, `status`, and
  `epochChanged`.

On-demand backup file creation and factory reset intentionally return
`MIGRATION_PENDING` in a Supabase deployment. Those are not safe browser
features: configure Supabase backups/PITR and the documented
export-and-restore runbook first. The Integrity screen can safely re-run its
read-only ledger/FIFO checks, but it never invents an automatic accounting
"repair" or claims that a backup or permanent deletion succeeded when it did
not.

## Required Supabase configuration

Set these custom secrets in the Supabase project; never put a server key in a
PWA, Sheet, or source-controlled `.env` file:

```text
CASHBOOK_ALLOWED_ORIGINS=https://owner.example.com,https://rep.example.com
```

Hosted Supabase functions inject `SUPABASE_URL` and the current
`SUPABASE_PUBLISHABLE_KEYS` / `SUPABASE_SECRET_KEYS` maps (with legacy key
variables on compatible projects). Do not attempt to create `SUPABASE_*`
secrets yourself; that prefix is reserved by Supabase.

The function must be deployed with JWT gateway verification disabled, because
the unchanged client contract sends an action body for login (which has no
token) and carries legacy-compatible session tokens in the body. The function
validates every non-login token itself through Supabase Auth and then invokes
RLS-protected database functions.

```toml
[functions.cashbook-api]
verify_jwt = false
```

`CASHBOOK_ALLOWED_ORIGINS` is mandatory in production. The function rejects a
request whose `Origin` is not on that allow-list before it reads a request body
or changes data. Only set `CASHBOOK_ALLOW_NO_ORIGIN=true` for controlled local
CLI administration; do not use it for a public deployment.

## Database contract

The accompanying SQL migrations provide these RLS-protected RPCs:

- `current_cashbook_context()` — derives the caller’s organisation, location,
  role and permissions from `auth.uid()`.
- `get_catalog_snapshot(p_organization_id, p_location_id)`
- `get_dashboard_summary(p_organization_id, p_location_id)`
- `post_sale(p_organization_id, p_client_id, p_sale)`
- `post_purchase`, `post_expense`, `post_party_payment`,
  `post_customer_return`, `post_stock_adjustment`, `post_owner_money`,
  `post_opening_balance`, `post_inventory_transfer`, and
  `reverse_cashbook_document`
- Operational RPCs from migration 907 for staff provisioning, approval queues,
  WhatsApp recipients and integrity reporting.

Login maps the familiar username to the private `profiles.email` value using a
server-side service client, then relies on Supabase Auth to verify the PIN. No
Apps Script password hashes or sessions are imported.

## Deploy safely

1. Apply the SQL migrations to a disposable development project.
2. Create the initial owner with Supabase Auth and a matching `profiles` /
   `memberships` record.
3. Configure the allow-listed PWA origins and function secrets.
4. Test against a product-only database with the current UI contract tests.
5. Pilot the static PWA URL with one owner. The Apps Script-hosted Owner page
   continues to use `google.script.run`; it is not silently switched.

Staff sign-in-only accounts generated from the Owner screen receive a reserved
`cashbook.invalid` Auth email unless the owner supplies a real email. This
preserves username/PIN login without pretending that staff have an email
recovery address. Supabase Auth requires a six-character minimum for these
staff PINs (owners require eight).

Do not use the function as a browser-to-table proxy. Direct client writes to
ledger, lot, stock, and payment tables must remain denied by RLS.
