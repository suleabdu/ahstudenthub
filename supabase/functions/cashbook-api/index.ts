/**
 * Cashbook compatibility API
 *
 * This is deliberately a thin boundary around the database command functions.
 * The existing Owner and Sales Rep PWAs already send a small JSON envelope:
 *
 *   { action, token, ...payload }
 *
 * Keeping that envelope means that the UI can move from Apps Script to
 * Supabase without rewriting every screen at the same time.  Financial state
 * is never assembled in this function: the PostgreSQL RPCs validate and post
 * each command inside a database transaction.
 *
 * Required Edge Function secrets:
 *   SUPABASE_URL
 *   SUPABASE_PUBLISHABLE_KEYS (or compatible singular/legacy key)
 *   SUPABASE_SECRET_KEYS (or compatible legacy service-role key)
 *   CASHBOOK_ALLOWED_ORIGINS     comma-separated static PWA origins
 *
 * `verify_jwt` is intentionally disabled for this function because login has
 * no token and the legacy clients carry their token in the JSON envelope.
 * Every non-login action is authenticated explicitly below.  Do not expose
 * the service role key to a browser.
 */
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

type Json = Record<string, unknown> | unknown[] | string | number | boolean | null;

type RequestEnvelope = {
  action?: unknown;
  token?: unknown;
  username?: unknown;
  pin?: unknown;
  device?: unknown;
  entries?: unknown;
  entry?: unknown;
  epoch?: unknown;
  location?: unknown;
  [key: string]: unknown;
};

type Membership = {
  organizationId: string;
  locationId?: string | null;
  role: "OWNER" | "REP" | string;
  permissions?: string[] | null;
};

type CashbookContext = {
  userId: string;
  username?: string | null;
  displayName?: string | null;
  defaultOrganizationId?: string | null;
  memberships?: Membership[] | null;
};

type Caller = {
  accessToken: string;
  userId: string;
  client: SupabaseClient;
  context: CashbookContext;
  membership: Membership;
};

class ApiError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly status = 400,
  ) {
    super(message);
  }
}

const MAX_SYNC_ENTRIES = 100;
const OWNER_ACTIONS = new Set([
  "batch",
  "dashboard",
  "products",
  "lists",
  "ledger",
  "statement",
  "stockCard",
  "report",
  "saveProduct",
  "saveProductImage",
  "imageLibrary",
  "productImportTemplate",
  "visionStatus",
  "resetPurchaseCosts",
  "importProducts",
  "previewProducts",
  "importOpeningStock",
  "previewOpeningStock",
  "parties",
  "saveParty",
  "users",
  "saveUser",
  "resetPin",
  "saveWhatsAppRecipients",
  "config",
  "saveConfig",
  "saveLocation",
  "closePeriod",
  "attention",
  "resolveAttention",
  "ackAttention",
  "audit",
  "backup",
  "integrity",
  "recalc",
  "resetPreview",
  "factoryReset",
]);

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new ApiError("SERVER", `Server configuration is missing ${name}.`, 500);
  return value;
}

function defaultInjectedKey(mapName: string, legacyNames: string[], label: string): string {
  const map = Deno.env.get(mapName);
  if (map) {
    try {
      const parsed = JSON.parse(map) as Record<string, unknown>;
      const key = typeof parsed.default === "string" ? parsed.default.trim() : "";
      if (key) return key;
      console.warn(`cashbook-api: ${mapName} has no default key; trying legacy key`);
    } catch {
      console.warn(`cashbook-api: could not parse ${mapName}; trying legacy key`);
    }
  }
  for (const legacyName of legacyNames) {
    const key = Deno.env.get(legacyName)?.trim();
    if (key) return key;
  }
  throw new ApiError("SERVER", `Server configuration is missing a Supabase ${label} key.`, 500);
}

function publishableKey(): string {
  // New hosted functions expose a JSON key map. The two singular variables
  // retain compatibility with older Supabase projects and local tooling.
  return defaultInjectedKey(
    "SUPABASE_PUBLISHABLE_KEYS",
    ["SUPABASE_PUBLISHABLE_KEY", "SUPABASE_ANON_KEY"],
    "publishable",
  );
}

function serviceKey(): string {
  return defaultInjectedKey("SUPABASE_SECRET_KEYS", ["SUPABASE_SERVICE_ROLE_KEY"], "server");
}

function json(body: Json, status = 200, headers: HeadersInit = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      ...headers,
    },
  });
}

function apiError(error: unknown): { code: string; error: string; status: number } {
  if (error instanceof ApiError) return { code: error.code, error: error.message, status: error.status };
  console.error("cashbook-api unexpected error", error);
  return { code: "SERVER", error: "Server error. Please try again or use the previous app while migration is in progress.", status: 500 };
}

function allowedOrigins(): Set<string> {
  return new Set(
    String(Deno.env.get("CASHBOOK_ALLOWED_ORIGINS") || "")
      .split(",")
      .map((origin) => origin.trim())
      .filter(Boolean),
  );
}

/**
 * Browser POSTs using text/plain do not always preflight.  We therefore
 * enforce Origin before doing *any* work, rather than treating CORS headers
 * as the security control.  Command-line clients can be enabled deliberately
 * with CASHBOOK_ALLOW_NO_ORIGIN=true for controlled admin tooling only.
 */
function corsFor(request: Request): HeadersInit {
  const origin = request.headers.get("origin") || "";
  const origins = allowedOrigins();
  const allowNoOrigin = Deno.env.get("CASHBOOK_ALLOW_NO_ORIGIN") === "true";

  if (!origin && !allowNoOrigin) {
    throw new ApiError("FORBIDDEN", "This API only accepts requests from an approved Cashbook app origin.", 403);
  }
  if (origin && !origins.has(origin)) {
    throw new ApiError("FORBIDDEN", "This app origin is not approved for Cashbook.", 403);
  }

  return {
    ...(origin ? { "access-control-allow-origin": origin } : {}),
    "access-control-allow-headers": "authorization, content-type, x-client-info, apikey",
    "access-control-allow-methods": "GET, POST, OPTIONS",
    "access-control-max-age": "86400",
    "vary": "Origin",
  };
}

function publicClient(): SupabaseClient {
  return createClient(env("SUPABASE_URL"), publishableKey(), {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
}

function serviceClient(): SupabaseClient {
  return createClient(env("SUPABASE_URL"), serviceKey(), {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
}

function clientFor(accessToken: string): SupabaseClient {
  return createClient(env("SUPABASE_URL"), publishableKey(), {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  });
}

async function readEnvelope(request: Request): Promise<RequestEnvelope> {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    throw new ApiError("BAD_REQUEST", "Could not read the request.");
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new ApiError("BAD_REQUEST", "Request must be a JSON object.");
  }
  if (typeof (body as RequestEnvelope).action !== "string" || !(body as RequestEnvelope).action.trim()) {
    throw new ApiError("BAD_REQUEST", "Request action is required.");
  }
  return body as RequestEnvelope;
}

function actionOf(request: RequestEnvelope): string {
  return String(request.action || "").trim();
}

function tokenFrom(httpRequest: Request, request: RequestEnvelope): string {
  const bearer = httpRequest.headers.get("authorization")?.match(/^Bearer\s+(.+)$/i)?.[1];
  const bodyToken = typeof request.token === "string" ? request.token.trim() : "";
  const token = bearer || bodyToken;
  if (!token) throw new ApiError("AUTH", "Please log in.", 401);
  return token;
}

function chooseMembership(context: CashbookContext): Membership {
  const memberships = (context.memberships || []).filter((membership) => membership && membership.organizationId);
  if (!memberships.length || !context.defaultOrganizationId) {
    throw new ApiError("AUTH", "Your account is not assigned to an active business. Contact an owner.", 403);
  }

  // A location filter is not an account selector. Owners commonly have a
  // company-wide membership (no locationId) and may choose any authorised
  // shop in the dashboard. Selecting a membership by `request.location`
  // would reject that normal owner workflow before the database's own
  // organisation/location validation could run. Reps remain scoped below by
  // requestedLocation(), which always uses their assigned location.
  const membership = memberships.find((candidate) => candidate.organizationId === context.defaultOrganizationId) || memberships[0];
  if (!membership) throw new ApiError("USER", "You do not have access to the selected shop.", 403);
  return membership;
}

async function callerFor(httpRequest: Request, request: RequestEnvelope): Promise<Caller> {
  const accessToken = tokenFrom(httpRequest, request);
  const anonymous = publicClient();
  const { data: auth, error: authError } = await anonymous.auth.getUser(accessToken);
  if (authError || !auth.user) throw new ApiError("AUTH", "Your session has ended. Please log in again.", 401);

  const client = clientFor(accessToken);
  const { data: context, error: contextError } = await client.rpc("current_cashbook_context");
  if (contextError || !context) {
    console.warn("cashbook context lookup failed", contextError?.message);
    throw new ApiError("AUTH", "Your account is not configured for Cashbook. Contact an owner.", 403);
  }
  const typedContext = context as CashbookContext;
  if (typedContext.userId !== auth.user.id) {
    throw new ApiError("AUTH", "Your session could not be verified.", 401);
  }

  return {
    accessToken,
    userId: auth.user.id,
    client,
    context: typedContext,
    membership: chooseMembership(typedContext),
  };
}

function requireOwner(caller: Caller, action: string): void {
  if (OWNER_ACTIONS.has(action) && caller.membership.role !== "OWNER") {
    throw new ApiError("USER", "You do not have permission to do that.", 403);
  }
}

function publicUser(context: CashbookContext, membership: Membership, fallbackUsername: string): Json {
  return {
    userId: context.userId,
    username: context.username || fallbackUsername,
    fullName: context.displayName || context.username || fallbackUsername,
    role: membership.role,
    location: membership.locationId || "",
    permissions: membership.permissions || [],
  };
}

async function lookupLoginEmail(username: string): Promise<{ email: string; username: string }> {
  const login = username.trim().toLowerCase();
  if (!login) throw new ApiError("USER", "Enter your username and PIN.");

  // An e-mail remains supported for the first owner account and recovery.
  if (login.includes("@")) return { email: login, username: login };

  const service = serviceClient();
  const { data, error } = await service
    .from("profiles")
    .select("email, username")
    // `profiles.username` is CITEXT, so equality is case-insensitive without
    // treating a login name as a SQL-pattern expression (`%`/`_`).
    .eq("username", login)
    .maybeSingle();
  if (error) {
    console.error("login alias lookup failed", error.message);
    throw new ApiError("SERVER", "Login is not configured yet. Ask an owner to finish Supabase setup.", 503);
  }
  if (!data?.email) throw new ApiError("USER", "Wrong username or PIN.", 401);
  return { email: String(data.email), username: String(data.username || login) };
}

async function login(request: RequestEnvelope): Promise<Json> {
  const username = typeof request.username === "string" ? request.username : "";
  const pin = typeof request.pin === "string" ? request.pin : "";
  if (!username.trim() || !pin) throw new ApiError("USER", "Enter your username and PIN.");

  const identity = await lookupLoginEmail(username);
  const anonymous = publicClient();
  const { data, error } = await anonymous.auth.signInWithPassword({ email: identity.email, password: pin });
  if (error || !data.session || !data.user) throw new ApiError("USER", "Wrong username or PIN.", 401);

  const client = clientFor(data.session.access_token);
  const { data: rawContext, error: contextError } = await client.rpc("current_cashbook_context");
  if (contextError || !rawContext) {
    console.warn("successful Auth login has no Cashbook context", contextError?.message);
    throw new ApiError("AUTH", "This account is not assigned to an active business. Contact an owner.", 403);
  }
  const context = rawContext as CashbookContext;
  const membership = chooseMembership(context);
  const expiresAt = data.session.expires_at ? new Date(data.session.expires_at * 1000).toISOString() : null;
  return {
    token: data.session.access_token,
    expiresAt,
    user: publicUser(context, membership, identity.username),
    // Password rotation can be added later with a profiles.must_change flag;
    // do not import old Apps Script password hashes into Auth.
    mustChange: false,
  };
}

async function callRpc<T extends Json>(caller: Caller, name: string, args: Record<string, unknown>): Promise<T> {
  const { data, error } = await caller.client.rpc(name, args);
  if (error) {
    console.error(`RPC ${name} failed`, error.code, error.message);
    // Our command/read RPCs use P0001 for validated business rules. Surface
    // those controlled messages to the person at the till instead of turning
    // an invalid date, party, or stock choice into a misleading server error.
    if (["P0001", "22007", "22P02", "23514", "23505"].includes(String(error.code || ""))) {
      throw new ApiError("USER", error.message || "The request needs correction.", 400);
    }
    if (String(error.code || "") === "42501") {
      throw new ApiError("USER", "You do not have permission to do that.", 403);
    }
    // Details can disclose table/function names or policy choices.  Keep the
    // full error only in the function logs and return a stable user message.
    throw new ApiError("SERVER", "The command could not be saved. Please retry; it has not been recorded if this message remains.", 500);
  }
  return data as T;
}

function requestedLocation(request: RequestEnvelope, caller: Caller): string | null {
  if (caller.membership.locationId) return caller.membership.locationId;
  const value = typeof request.location === "string" ? request.location.trim() : "";
  return value || null;
}

function requestObject(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function optionalText(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function optionalInteger(value: unknown, fallback: number): number {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isInteger(parsed) ? parsed : fallback;
}

async function snapshot(caller: Caller, request: RequestEnvelope): Promise<Json> {
  return await callRpc<Json>(caller, "get_catalog_snapshot", {
    p_organization_id: caller.membership.organizationId,
    p_location_id: requestedLocation(request, caller),
  });
}

async function dashboard(caller: Caller, request: RequestEnvelope): Promise<Json> {
  return await callRpc<Json>(caller, "get_dashboard_summary", {
    p_organization_id: caller.membership.organizationId,
    p_location_id: requestedLocation(request, caller),
  });
}

function entryType(entry: unknown): string {
  return entry && typeof entry === "object" && !Array.isArray(entry)
    ? String((entry as Record<string, unknown>).type || "").trim().toUpperCase()
    : "";
}

function clientId(entry: unknown): string {
  return entry && typeof entry === "object" && !Array.isArray(entry)
    ? String((entry as Record<string, unknown>).clientId || "").trim()
    : "";
}

async function postCommand(caller: Caller, rpcName: string, argumentName: string, entry: unknown): Promise<Json> {
  const body = requestObject(entry);
  const id = clientId(body);
  if (!id) return { clientId: "", status: "ERROR", message: "This saved action has no client reference. It was not posted." };
  const result = await callRpc<Json>(caller, rpcName, {
    p_organization_id: caller.membership.organizationId,
    p_client_id: id,
    [argumentName]: body,
  });
  return result && typeof result === "object" && !Array.isArray(result)
    ? { clientId: id, ...(result as Record<string, unknown>) }
    : { clientId: id, status: "ERROR", message: "The saved action returned an invalid result." };
}

async function postEntry(caller: Caller, entry: unknown): Promise<Json> {
  const type = entryType(entry);
  const id = clientId(entry);
  const body = requestObject(entry);
  switch (type) {
    case "SALE":
      return await postCommand(caller, "post_sale", "p_sale", body);
    case "OPENING_STOCK":
      return await postCommand(caller, "post_opening_stock", "p_opening", body);
    case "STOCK_IN":
      return body.opening === true
        ? await postCommand(caller, "post_opening_stock", "p_opening", body)
        : await postCommand(caller, "post_purchase", "p_purchase", body);
    case "PURCHASE":
      return await postCommand(caller, "post_purchase", "p_purchase", body);
    case "EXPENSE":
      return await postCommand(caller, "post_expense", "p_expense", body);
    case "PAYMENT_IN":
    case "PAYMENT_OUT":
      return await postCommand(caller, "post_party_payment", "p_payment", body);
    case "RETURN":
      return await postCommand(caller, "post_customer_return", "p_return", body);
    case "OWNER_CONTRIBUTION":
    case "OWNER_WITHDRAWAL":
      return await postCommand(caller, "post_owner_money", "p_money", body);
    case "ADJUSTMENT":
      return await postCommand(caller, "post_stock_adjustment", "p_adjustment", body);
    case "TRANSFER":
      return await postCommand(caller, "post_inventory_transfer", "p_transfer", body);
    case "OPENING_BAL":
      return await postCommand(caller, "post_opening_balance", "p_opening", body);
    case "REVERSAL":
      return await postCommand(caller, "reverse_cashbook_document", "p_reversal", body);
    case "ADD_PRODUCT":
      return await postCommand(caller, "post_staff_product_request", "p_product", body);
    default:
      return { clientId: id, status: "ERROR", message: `${type || "This"} action is not recognised by Cashbook.` };
  }
}

function csvRows(text: string): string[][] {
  const rows: string[][] = [];
  const source = text.replace(/^\uFEFF/, "");
  const first = source.split(/\r?\n/, 1)[0] || "";
  const delimiter = first.includes("\t") ? "\t" : ",";
  let row: string[] = [], field = "", quoted = false;
  for (let index = 0; index < source.length; index += 1) {
    const character = source[index];
    if (quoted) {
      if (character === '"' && source[index + 1] === '"') { field += '"'; index += 1; }
      else if (character === '"') quoted = false;
      else field += character;
      continue;
    }
    if (character === '"') { quoted = true; continue; }
    if (character === delimiter) { row.push(field.trim()); field = ""; continue; }
    if (character === "\n") { row.push(field.replace(/\r$/, "").trim()); if (row.some(value => value)) rows.push(row); row = []; field = ""; continue; }
    field += character;
  }
  if (quoted) throw new ApiError("USER", "The pasted list has an unclosed quoted value.");
  if (field || row.length) { row.push(field.replace(/\r$/, "").trim()); if (row.some(value => value)) rows.push(row); }
  return rows;
}

function header(value: string): string {
  return value.trim().toLowerCase().replace(/[\s_-]+/g, " ");
}

function headerPosition(headers: string[], aliases: string[]): number {
  return headers.findIndex(value => aliases.includes(header(value)));
}

function productImportRows(text: unknown): Array<Record<string, unknown>> {
  const rows = csvRows(typeof text === "string" ? text : "");
  if (!rows.length) throw new ApiError("USER", "Paste at least one product row.");
  const first = rows[0].map(header);
  const hasHeader = first.includes("sku") || first.includes("product code");
  const offset = hasHeader ? 1 : 0;
  const headings = hasHeader ? rows[0] : ["SKU", "Name", "Category", "Unit", "Selling Price", "Reorder Level", "Type"];
  const index = {
    sku: headerPosition(headings, ["sku", "product code", "code"]),
    name: headerPosition(headings, ["name", "product name", "product"]),
    category: headerPosition(headings, ["category"]),
    unit: headerPosition(headings, ["unit", "uom"]),
    sellingPrice: headerPosition(headings, ["selling price", "sellingprice", "price", "sale price"]),
    reorderLevel: headerPosition(headings, ["reorder level", "reorderlevel", "reorder", "minimum stock"]),
    type: headerPosition(headings, ["type", "product type"]),
    legacyDriveFileId: headerPosition(headings, ["image file id", "imagefileid", "drive file id"]),
    imageName: headerPosition(headings, ["image name", "imagename"]),
  };
  if (index.sku < 0 || index.name < 0 || index.unit < 0 || index.sellingPrice < 0) {
    throw new ApiError("USER", "Use columns for SKU, Name, Category, Unit, Selling Price, Reorder Level, and Type.");
  }
  const at = (row: string[], key: keyof typeof index) => index[key] >= 0 ? (row[index[key]] || "").trim() : "";
  return rows.slice(offset).map((row, position) => ({
    sourceRow: position + offset + 1,
    sku: at(row, "sku"), name: at(row, "name"), category: at(row, "category"), unit: at(row, "unit"),
    sellingPrice: at(row, "sellingPrice"), reorderLevel: at(row, "reorderLevel"), type: at(row, "type") || "ITEM",
    legacyDriveFileId: at(row, "legacyDriveFileId") || null, imageName: at(row, "imageName") || null,
  })).filter(row => Object.values(row).some(value => value !== "" && value !== null));
}

function importPreviewShape(data: Json): Json {
  const preview = data && typeof data === "object" && !Array.isArray(data) ? data as Record<string, unknown> : {};
  const rows = Array.isArray(preview.rows) ? preview.rows : [];
  return {
    batchId: preview.batchId,
    ok: preview.ok === true,
    valid: Number(preview.valid || 0),
    invalid: Number(preview.invalid || 0),
    rows: rows.map(row => {
      const item = row && typeof row === "object" && !Array.isArray(row) ? row as Record<string, unknown> : {};
      const errors = Array.isArray(item.errors) ? item.errors.map(String) : [];
      return { line: item.row, sku: item.sku || "", name: item.name || "", type: item.type || "", ok: item.valid === true, message: errors.join(" ") };
    }),
  };
}

async function previewProducts(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const rows = productImportRows(request.text);
  const result = await callRpc<Json>(caller, "preview_product_import", {
    p_organization_id: caller.membership.organizationId,
    p_source_name: "Owner app product import",
    p_rows: rows,
  });
  return importPreviewShape(result);
}

async function importProducts(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const rows = productImportRows(request.text);
  const preview = await callRpc<Json>(caller, "preview_product_import", {
    p_organization_id: caller.membership.organizationId,
    p_source_name: "Owner app product import",
    p_rows: rows,
  });
  const typed = preview && typeof preview === "object" && !Array.isArray(preview) ? preview as Record<string, unknown> : {};
  if (typed.ok !== true || typeof typed.batchId !== "string") {
    const shaped = importPreviewShape(preview) as Record<string, unknown>;
    const rowsWithErrors = Array.isArray(shaped.rows) ? shaped.rows as Array<Record<string, unknown>> : [];
    return { added: 0, skipped: rowsWithErrors.filter(row => !row.ok).map(row => `Line ${row.line}: ${row.message}`) };
  }
  return await callRpc<Json>(caller, "promote_product_import", {
    p_organization_id: caller.membership.organizationId,
    p_batch_id: typed.batchId,
  });
}

async function postOpeningStock(caller: Caller, entry: unknown): Promise<Json> {
  const body = entry && typeof entry === "object" && !Array.isArray(entry) ? entry as Record<string, unknown> : {};
  const id = clientId(body);
  if (!id) return { clientId: "", status: "ERROR", message: "This saved action has no client reference. It was not posted." };
  const result = await callRpc<Json>(caller, "post_opening_stock", {
    p_organization_id: caller.membership.organizationId,
    p_client_id: id,
    p_opening: body,
  });
  return result && typeof result === "object" && !Array.isArray(result) ? { clientId: id, ...(result as Record<string, unknown>) } : { clientId: id, status: "ERROR", message: "The opening-stock command returned an invalid result." };
}

function decimal(value: string): number | null {
  const cleaned = value.trim().replace(/,/g, "");
  return /^[+]?(?:\d+(?:\.\d*)?|\.\d+)$/.test(cleaned) ? Number(cleaned) : null;
}

async function openingImportPreview(caller: Caller, request: RequestEnvelope): Promise<{ok: boolean; valid: number; invalid: number; rows: Array<Record<string, unknown>>; items: Array<Record<string, unknown>>}> {
  const text = request.text;
  const source = csvRows(typeof text === "string" ? text : "");
  if (!source.length) throw new ApiError("USER", "Paste at least one opening-stock row.");
  const startsWithHeader = header(source[0][0] || "") === "sku";
  const snapshotData = await snapshot(caller, request) as Record<string, unknown>;
  const products = new Map<string, Record<string, unknown>>();
  (Array.isArray(snapshotData.products) ? snapshotData.products : []).forEach(product => {
    if (product && typeof product === "object" && !Array.isArray(product)) {
      const row = product as Record<string, unknown>;
      products.set(String(row.sku || "").toUpperCase(), row);
    }
  });
  const seen = new Set<string>();
  const rows: Array<Record<string, unknown>> = [];
  const items: Array<Record<string, unknown>> = [];
  source.slice(startsWithHeader ? 1 : 0).forEach((row, position) => {
    const sku = String(row[0] || "").trim().toUpperCase();
    const quantity = decimal(String(row[1] || ""));
    const cost = decimal(String(row[2] || ""));
    const product = products.get(sku);
    const errors: string[] = [];
    if (!product) errors.push("Product SKU was not found.");
    else if (product.type !== "ITEM") errors.push("This is a service and cannot have stock.");
    if (quantity === null || !(quantity > 0) || Math.abs(quantity * 10000 - Math.round(quantity * 10000)) > 0.000001) errors.push("Quantity must be above zero with up to four decimal places.");
    if (cost === null || !(cost > 0)) errors.push("Purchase cost must be above zero.");
    if (sku && seen.has(sku)) errors.push("This SKU appears more than once. Combine its quantities first.");
    if (sku) seen.add(sku);
    rows.push({ line: position + (startsWithHeader ? 2 : 1), sku, name: product?.name || "", qty: quantity || 0, cost: cost || 0, ok: errors.length === 0, message: errors.join(" ") });
    if (!errors.length) items.push({ sku, qty: quantity, unitCost: cost });
  });
  const valid = rows.filter(row => row.ok).length;
  return {ok: rows.length > 0 && valid === rows.length, valid, invalid: rows.length - valid, rows, items};
}

async function previewOpeningStock(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const preview = await openingImportPreview(caller, request);
  return {ok: preview.ok, valid: preview.valid, invalid: preview.invalid, rows: preview.rows};
}

async function importOpeningStock(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const preview = await openingImportPreview(caller, request);
  if (!preview.ok) return {added: 0, docNo: "", skipped: preview.rows.filter(row => !row.ok).map(row => `Line ${row.line}: ${row.message}`)};
  const id = typeof request.clientId === "string" && request.clientId.trim() ? request.clientId.trim() : crypto.randomUUID();
  const result = await postOpeningStock(caller, {
    clientId: id, type: "OPENING_STOCK", date: request.date, location: request.location,
    notes: "Opening stock import", items: preview.items,
  });
  const typed = result && typeof result === "object" && !Array.isArray(result) ? result as Record<string, unknown> : {};
  if (typed.status !== "OK" && typed.status !== "DUPLICATE") return {added: 0, docNo: "", skipped: [String(typed.message || "Opening stock could not be saved.")]};
  return {added: preview.items.length, docNo: typed.docNo || "", skipped: []};
}

async function lists(caller: Caller): Promise<Json> {
  return await callRpc<Json>(caller, "get_lists", { p_organization_id: caller.membership.organizationId });
}

async function products(caller: Caller, request: RequestEnvelope): Promise<Json> {
  return await callRpc<Json>(caller, "get_products", {
    p_organization_id: caller.membership.organizationId,
    p_location: requestedLocation(request, caller),
  });
}

async function parties(caller: Caller): Promise<Json> {
  return await callRpc<Json>(caller, "get_parties", { p_organization_id: caller.membership.organizationId });
}

async function ledger(caller: Caller, request: RequestEnvelope): Promise<Json> {
  return await callRpc<Json>(caller, "get_ledger", {
    p_organization_id: caller.membership.organizationId,
    p_type: optionalText(request.type),
    p_from: optionalText(request.from),
    p_to: optionalText(request.to),
    p_location: requestedLocation(request, caller),
    p_query: optionalText(request.q),
    p_limit: optionalInteger(request.limit, 150),
  });
}

async function statement(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const partyId = optionalText(request.partyId);
  if (!partyId) throw new ApiError("USER", "Choose a customer or supplier.");
  return await callRpc<Json>(caller, "get_statement", {
    p_organization_id: caller.membership.organizationId,
    p_party_id: partyId,
  });
}

async function stockCard(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const sku = optionalText(request.sku);
  if (!sku) throw new ApiError("USER", "Choose a product.");
  return await callRpc<Json>(caller, "get_stock_card", {
    p_organization_id: caller.membership.organizationId,
    p_sku: sku,
    p_location: requestedLocation(request, caller),
  });
}

async function report(caller: Caller, request: RequestEnvelope): Promise<Json> {
  return await callRpc<Json>(caller, "get_report", {
    p_organization_id: caller.membership.organizationId,
    p_group: optionalText(request.group) || "day",
    p_from: optionalText(request.from),
    p_to: optionalText(request.to),
    p_location: requestedLocation(request, caller),
  });
}

async function attention(caller: Caller, request: RequestEnvelope): Promise<Json> {
  return await callRpc<Json>(caller, "get_attention", {
    p_organization_id: caller.membership.organizationId,
    p_location: requestedLocation(request, caller),
  });
}

async function audit(caller: Caller, request: RequestEnvelope): Promise<Json> {
  return await callRpc<Json>(caller, "get_audit", {
    p_organization_id: caller.membership.organizationId,
    p_limit: optionalInteger(request.limit, 200),
  });
}

async function users(caller: Caller): Promise<Json> {
  return await callRpc<Json>(caller, "get_users", { p_organization_id: caller.membership.organizationId });
}

async function config(caller: Caller): Promise<Json> {
  return await callRpc<Json>(caller, "get_config", { p_organization_id: caller.membership.organizationId });
}

async function saveProduct(caller: Caller, request: RequestEnvelope): Promise<Json> {
  return await callRpc<Json>(caller, "upsert_product", {
    p_organization_id: caller.membership.organizationId,
    p_product: requestObject(request.product),
  });
}

async function saveParty(caller: Caller, request: RequestEnvelope): Promise<Json> {
  return await callRpc<Json>(caller, "upsert_party", {
    p_organization_id: caller.membership.organizationId,
    p_party: requestObject(request.party),
  });
}

async function saveLocation(caller: Caller, request: RequestEnvelope): Promise<Json> {
  return await callRpc<Json>(caller, "upsert_location", {
    p_organization_id: caller.membership.organizationId,
    p_location: requestObject(request.location),
  });
}

async function saveConfig(caller: Caller, request: RequestEnvelope): Promise<Json> {
  return await callRpc<Json>(caller, "update_settings", {
    p_organization_id: caller.membership.organizationId,
    p_values: requestObject(request.values),
  });
}

async function closePeriod(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const date = optionalText(request.date);
  if (!date) throw new ApiError("USER", "Choose a valid date.");
  return await callRpc<Json>(caller, "close_period", {
    p_organization_id: caller.membership.organizationId,
    p_date: date,
  });
}

async function resolveAttention(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const keys = Array.isArray(request.keys) ? request.keys.filter(key => typeof key === "string") : [];
  if (!keys.length) throw new ApiError("USER", "Select at least one attention item.");
  return await callRpc<Json>(caller, "acknowledge_attention", {
    p_organization_id: caller.membership.organizationId,
    p_keys: keys,
    p_resolution: optionalText(request.resolution) || "RESOLVED",
    p_note: optionalText(request.note),
  });
}

async function acknowledgeAllAttention(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const current = await attention(caller, request);
  const items = current && typeof current === "object" && !Array.isArray(current)
    ? (current as Record<string, unknown>).items
    : [];
  const keys = Array.isArray(items)
    ? items.map(item => item && typeof item === "object" ? String((item as Record<string, unknown>).key || "") : "").filter(Boolean)
    : [];
  if (!keys.length) return { saved: true, changed: 0, action: "RESOLVE" };
  return await callRpc<Json>(caller, "acknowledge_attention", {
    p_organization_id: caller.membership.organizationId,
    p_keys: keys,
    p_resolution: "RESOLVED",
    p_note: "Marked reviewed from the Home dashboard.",
  });
}

const BATCH_READ_ACTIONS = new Set([
  "lists", "dashboard", "products", "parties", "ledger", "statement",
  "stockCard", "report", "attention", "audit", "users", "config",
  "previewProducts", "previewOpeningStock",
]);

async function readAction(caller: Caller, action: string, request: RequestEnvelope): Promise<Json> {
  switch (action) {
    case "lists": return await lists(caller);
    case "dashboard": return await dashboard(caller, request);
    case "products": return await products(caller, request);
    case "parties": return await parties(caller);
    case "ledger": return await ledger(caller, request);
    case "statement": return await statement(caller, request);
    case "stockCard": return await stockCard(caller, request);
    case "report": return await report(caller, request);
    case "attention": return await attention(caller, request);
    case "audit": return await audit(caller, request);
    case "users": return await users(caller);
    case "config": return await config(caller);
    case "previewProducts": return await previewProducts(caller, request);
    case "previewOpeningStock": return await previewOpeningStock(caller, request);
    default: throw new ApiError("USER", "That action cannot be included in a batch.");
  }
}

async function batch(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const requests = Array.isArray(request.requests) ? request.requests.slice(0, 10) : [];
  if (!requests.length) throw new ApiError("USER", "Add between 1 and 10 read requests.");
  const results: Array<Record<string, unknown>> = [];
  for (const raw of requests) {
    const child = requestObject(raw) as RequestEnvelope;
    const action = actionOf(child);
    if (!BATCH_READ_ACTIONS.has(action)) {
      results.push({ ok: false, code: "USER", error: "That action cannot be included in a batch." });
      continue;
    }
    try {
      results.push({ ok: true, data: await readAction(caller, action, child) });
    } catch (error) {
      const out = apiError(error);
      results.push({ ok: false, code: out.code, error: out.error });
    }
  }
  return { results };
}

async function sync(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const entries = Array.isArray(request.entries) ? request.entries : [];
  if (entries.length > MAX_SYNC_ENTRIES) throw new ApiError("USER", `Too many entries in one sync (max ${MAX_SYNC_ENTRIES}).`);

  const before = await snapshot(caller, request);
  const currentEpoch = before && typeof before === "object" && !Array.isArray(before)
    ? Number((before as Record<string, unknown>).epoch)
    : NaN;
  if (request.epoch !== undefined && Number.isFinite(currentEpoch) && Number(request.epoch) !== currentEpoch) {
    return { results: [], epochChanged: true, snapshot: before };
  }

  const results: Json[] = [];
  for (const entry of entries) {
    try {
      results.push(await postEntry(caller, entry));
    } catch (error) {
      const e = apiError(error);
      results.push({ clientId: clientId(entry), status: "ERROR", message: e.error });
    }
  }
  return { results, snapshot: await snapshot(caller, request) };
}

async function changePin(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const oldPin = typeof request.oldPin === "string" ? request.oldPin : "";
  const newPin = typeof request.newPin === "string" ? request.newPin : "";
  // Supabase Auth defaults to a six-character minimum. Keep the browser
  // message aligned with the server so a valid-looking four/five-character
  // staff PIN never turns into a misleading storage error after verification.
  const minLength = caller.membership.role === "OWNER" ? 8 : 6;
  if (!oldPin || !newPin) throw new ApiError("USER", "Enter your current and new PIN.");
  if (newPin.length < minLength) throw new ApiError("USER", caller.membership.role === "OWNER" ? "Owner passwords need at least 8 characters." : "Staff PINs need at least 6 characters.");

  const anonymous = publicClient();
  const { data: current, error: currentError } = await anonymous.auth.getUser(caller.accessToken);
  if (currentError || !current.user?.email) throw new ApiError("AUTH", "Your session has ended. Please log in again.", 401);
  const { error: verificationError } = await anonymous.auth.signInWithPassword({ email: current.user.email, password: oldPin });
  if (verificationError) throw new ApiError("USER", "Your current PIN is not correct.");

  const { error: updateError } = await serviceClient().auth.admin.updateUserById(caller.userId, { password: newPin });
  if (updateError) {
    console.error("PIN update failed", updateError.message);
    throw new ApiError("SERVER", "Could not update the PIN. Please try again.", 500);
  }
  return { changed: true };
}

function profileInput(user: Record<string, unknown>): Record<string, unknown> {
  // Credentials are an Auth concern. Never pass an operator's plaintext PIN
  // into a database profile/membership function or an audit event.
  const input = { ...user };
  delete input.pin;
  delete input.password;
  return input;
}

function accountEmailFor(user: Record<string, unknown>, organizationId: string): string {
  const supplied = optionalText(user.email)?.toLowerCase() || "";
  if (supplied) {
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(supplied) || supplied.length > 254) {
      throw new ApiError("USER", "Enter a valid staff email address, or leave it blank to create a sign-in-only account.");
    }
    return supplied;
  }
  const username = String(user.username || "").trim().toLowerCase().replace(/[^a-z0-9._-]/g, "");
  if (!username || username.length > 80) throw new ApiError("USER", "Enter a valid username before creating the account.");
  // A reserved .invalid address lets the existing username/PIN experience
  // work without pretending that a staff mailbox has been verified. Owners
  // can still supply a genuine recovery address when one is available.
  const organization = organizationId.replace(/[^a-f0-9]/gi, "").slice(0, 12).toLowerCase() || "business";
  return `cashbook+${organization}-${username.slice(0, 60)}-${crypto.randomUUID().slice(0, 12)}@cashbook.invalid`;
}

function passwordForNewAccount(user: Record<string, unknown>): string {
  const pin = optionalText(user.pin) || "";
  const role = String(user.role || "REP").trim().toUpperCase();
  const minimum = role === "OWNER" ? 8 : 6;
  if (pin.length < minimum) {
    throw new ApiError("USER", role === "OWNER"
      ? "Owner passwords need at least 8 characters."
      : "Staff PINs need at least 6 characters for Supabase Auth.");
  }
  return pin;
}

async function saveUser(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const user = requestObject(request.user);
  const currentUserId = optionalText(user.userId);
  const profile = profileInput(user);

  if (currentUserId) {
    return await callRpc<Json>(caller, "upsert_cashbook_user_profile", {
      p_organization_id: caller.membership.organizationId,
      p_user_id: currentUserId,
      p_user: profile,
    });
  }

  const username = optionalText(user.username);
  const fullName = optionalText(user.fullName);
  if (!username || !fullName) throw new ApiError("USER", "Enter the staff member's full name and username.");
  const password = passwordForNewAccount(user);
  const email = accountEmailFor(user, caller.membership.organizationId);
  const service = serviceClient();
  const { data: created, error: createError } = await service.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: { cashbook_username: username, cashbook_display_name: fullName },
  });
  if (createError || !created.user) {
    console.error("cashbook user creation failed", createError?.message);
    throw new ApiError("USER", "That username or email cannot be used for a new Cashbook account. Choose another one.", 400);
  }

  try {
    const saved = await callRpc<Json>(caller, "upsert_cashbook_user_profile", {
      p_organization_id: caller.membership.organizationId,
      p_user_id: created.user.id,
      p_user: profile,
    });
    return saved && typeof saved === "object" && !Array.isArray(saved)
      ? { ...(saved as Record<string, unknown>), userId: created.user.id, created: true }
      : { saved: true, userId: created.user.id, created: true };
  } catch (error) {
    // Do not leave an Auth account that has no organisation membership when
    // the database side of account creation fails.
    const { error: cleanupError } = await service.auth.admin.deleteUser(created.user.id);
    if (cleanupError) console.error("cashbook user cleanup failed", cleanupError.message);
    throw error;
  }
}

async function resetPin(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const userId = optionalText(request.userId);
  const newPin = optionalText(request.newPin) || "";
  if (!userId) throw new ApiError("USER", "Choose the staff member whose PIN you want to reset.");
  if (newPin.length < 6) throw new ApiError("USER", "Staff PINs need at least 6 characters for Supabase Auth.");

  // This SQL check is deliberately before the service-role update. It proves
  // that the selected Auth user is an account the current owner may manage.
  await callRpc<Json>(caller, "assert_manageable_cashbook_user", {
    p_organization_id: caller.membership.organizationId,
    p_user_id: userId,
  });
  const { error } = await serviceClient().auth.admin.updateUserById(userId, { password: newPin });
  if (error) {
    console.error("cashbook PIN reset failed", error.message);
    throw new ApiError("SERVER", "The PIN could not be reset. It was not changed; please retry.", 500);
  }
  // Supabase only permits a user to globally revoke their own sessions with
  // that user's JWT.  Do not claim an administrator can revoke an arbitrary
  // access token by ID: membership is still checked on every command and the
  // new PIN is required at the next sign-in/refresh.
  return { reset: true, userId, sessionRevoked: false };
}

async function whatsAppRecipients(caller: Caller): Promise<Json> {
  return await callRpc<Json>(caller, "get_whatsapp_recipients", {
    p_organization_id: caller.membership.organizationId,
  });
}

async function saveWhatsAppRecipients(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const rows = Array.isArray(request.rows) ? request.rows : [];
  return await callRpc<Json>(caller, "save_whatsapp_recipients", {
    p_organization_id: caller.membership.organizationId,
    p_rows: rows,
  });
}

async function integrity(caller: Caller): Promise<Json> {
  return await callRpc<Json>(caller, "get_integrity_check", {
    p_organization_id: caller.membership.organizationId,
  });
}

async function resetPreview(caller: Caller): Promise<Json> {
  return await callRpc<Json>(caller, "get_reset_preview", {
    p_organization_id: caller.membership.organizationId,
  });
}

async function resetPurchaseCosts(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const updates = Array.isArray(request.updates) ? request.updates : [];
  const applyToStock = request.applyToStock === true;
  const reason = optionalText(request.reason) || "";
  const confirmation = optionalText(request.confirmation) || "";
  return await callRpc<Json>(caller, "reset_purchase_costs", {
    p_organization_id: caller.membership.organizationId,
    p_updates: updates,
    p_apply_to_stock: applyToStock,
    p_reason: reason,
    p_confirmation: confirmation,
  });
}

async function recalculateReadModels(caller: Caller): Promise<Json> {
  // The corresponding database routine deliberately performs no destructive
  // "repair". It re-runs the immutable-ledger integrity analysis and returns
  // the screen shape the existing Owner UI expects.
  return await callRpc<Json>(caller, "recalculate_cashbook_read_models", {
    p_organization_id: caller.membership.organizationId,
  });
}

function migrationRequired(feature: string): never {
  throw new ApiError(
    "MIGRATION_PENDING",
    `${feature} is intentionally disabled in the Supabase pilot. Enable the documented production backup/recovery workflow before using it.`,
    409,
  );
}

type ImageBytes = {
  bytes: Uint8Array;
  mimeType: "image/jpeg" | "image/png" | "image/webp";
  fingerprint: string;
};

function imageDataValue(request: RequestEnvelope): string {
  const image = request.image && typeof request.image === "object" && !Array.isArray(request.image)
    ? request.image as Record<string, unknown> : {};
  const value = request.imageData ?? request.base64 ?? request.data ?? image.base64;
  return typeof value === "string" ? value.trim() : "";
}

async function readImageBytes(request: RequestEnvelope): Promise<ImageBytes> {
  const source = imageDataValue(request);
  const match = /^data:(image\/(?:jpeg|png|webp));base64,([A-Za-z0-9+/=\s]+)$/i.exec(source);
  if (!match) throw new ApiError("USER", "Use a JPG, PNG or WebP product image.");
  const mimeType = match[1].toLowerCase() as ImageBytes["mimeType"];
  let raw: string;
  try {
    raw = atob(match[2].replace(/\s/g, ""));
  } catch {
    throw new ApiError("USER", "The image data could not be read.");
  }
  if (!raw.length || raw.length > 5 * 1024 * 1024) {
    throw new ApiError("USER", "Use an image smaller than 5 MB.");
  }
  const bytes = Uint8Array.from(raw, (character) => character.charCodeAt(0));
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  const fingerprint = Array.from(digest, (byte) => byte.toString(16).padStart(2, "0")).join("");
  return { bytes, mimeType, fingerprint };
}

function imageFileName(sku: string, source: unknown, mimeType: ImageBytes["mimeType"]): string {
  const extension = mimeType === "image/png" ? "png" : mimeType === "image/webp" ? "webp" : "jpg";
  const stem = String(source || sku || "product-image")
    .replace(/\.[A-Za-z0-9]{1,8}$/, "")
    .replace(/[^A-Za-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 70) || "product-image";
  return `${sku}-${stem}-${crypto.randomUUID().slice(0, 8)}.${extension}`;
}

async function productForImage(caller: Caller, skuInput: unknown): Promise<Record<string, unknown>> {
  const sku = optionalText(skuInput)?.toUpperCase() || "";
  if (!/^[A-Z0-9._/#-]{1,40}$/.test(sku)) throw new ApiError("USER", "Choose a valid product before uploading its image.");
  const { data, error } = await serviceClient()
    .from("products")
    .select("id,sku,name,category,unit,selling_price,kind")
    .eq("organization_id", caller.membership.organizationId)
    .ilike("sku", sku)
    .maybeSingle();
  if (error) {
    console.error("product image lookup failed", error.message);
    throw new ApiError("SERVER", "Could not find that product. Please retry.", 500);
  }
  if (!data) throw new ApiError("USER", "Choose a product before uploading its image.");
  return data as Record<string, unknown>;
}

function imageProductShape(product: Record<string, unknown>, image: Record<string, unknown>): Record<string, unknown> {
  return {
    sku: String(product.sku || ""),
    name: String(product.name || ""),
    category: String(product.category || ""),
    unit: String(product.unit || ""),
    price: Number(product.selling_price || 0),
    type: String(product.kind || "ITEM"),
    image,
  };
}

async function saveProductImage(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const product = await productForImage(caller, request.sku);
  const image = await readImageBytes(request);
  const productId = String(product.id);
  const fileName = imageFileName(String(product.sku || "PRODUCT"), request.name, image.mimeType);
  const storagePath = `${caller.membership.organizationId}/${productId}/${fileName}`;
  const service = serviceClient();
  const { error: uploadError } = await service.storage.from("product-images").upload(storagePath, image.bytes, {
    contentType: image.mimeType,
    upsert: false,
  });
  if (uploadError) {
    console.error("product image upload failed", uploadError.message);
    throw new ApiError("SERVER", "The product photo could not be saved. Please retry.", 500);
  }

  const { data: prior, error: priorError } = await service
    .from("product_images")
    .select("id,storage_path")
    .eq("organization_id", caller.membership.organizationId)
    .eq("product_id", productId)
    .eq("is_primary", true);
  if (priorError) {
    await service.storage.from("product-images").remove([storagePath]);
    console.error("product image metadata lookup failed", priorError.message);
    throw new ApiError("SERVER", "The product photo could not be recorded. Please retry.", 500);
  }

  const { error: demoteError } = await service
    .from("product_images")
    .update({ is_primary: false })
    .eq("organization_id", caller.membership.organizationId)
    .eq("product_id", productId)
    .eq("is_primary", true);
  if (demoteError) {
    await service.storage.from("product-images").remove([storagePath]);
    console.error("product image metadata update failed", demoteError.message);
    throw new ApiError("SERVER", "The product photo could not be recorded. Please retry.", 500);
  }

  const { data: stored, error: insertError } = await service
    .from("product_images")
    .insert({
      organization_id: caller.membership.organizationId,
      product_id: productId,
      storage_path: storagePath,
      file_name: fileName,
      mime_type: image.mimeType,
      fingerprint: image.fingerprint,
      is_primary: true,
      created_by: caller.userId,
    })
    .select("id,storage_path,file_name,mime_type,fingerprint,created_at")
    .single();
  if (insertError || !stored) {
    // Restore the previous primary marker where possible, then remove the
    // orphaned private object. This is compensating cleanup only; financial
    // records are not involved in image storage.
    if (Array.isArray(prior) && prior.length) {
      await service.from("product_images").update({ is_primary: true }).in("id", prior.map((row) => String(row.id)));
    }
    await service.storage.from("product-images").remove([storagePath]);
    console.error("product image metadata insert failed", insertError?.message);
    throw new ApiError("SERVER", "The product photo could not be recorded. Please retry.", 500);
  }

  const oldPaths = Array.isArray(prior) ? prior.map((row) => String(row.storage_path || "")).filter(Boolean) : [];
  if (oldPaths.length) await service.storage.from("product-images").remove(oldPaths);
  const { error: auditError } = await service.from("audit_events").insert({
    organization_id: caller.membership.organizationId,
    actor_id: caller.userId,
    action: "PRODUCT_IMAGE_SAVED",
    entity_type: "product",
    entity_id: productId,
    outcome: "OK",
    detail: { sku: String(product.sku || ""), fileName, fingerprint: image.fingerprint },
  });
  if (auditError) console.error("product image audit write failed", auditError.message);

  return {
    saved: true,
    folderId: "product-images",
    product: imageProductShape(product, {
      fileId: String(stored.id || ""),
      name: fileName,
      fingerprint: image.fingerprint,
      updatedAt: String(stored.created_at || ""),
    }),
  };
}

async function imageLibrary(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const wantedSku = optionalText(request.sku)?.toUpperCase() || "";
  const service = serviceClient();
  const { data: products, error: productError } = await service
    .from("products")
    .select("id,sku,name,category,unit,selling_price,kind")
    .eq("organization_id", caller.membership.organizationId)
    .eq("active", true);
  if (productError) {
    console.error("product image library product lookup failed", productError.message);
    throw new ApiError("SERVER", "Could not load the product image library. Please retry.", 500);
  }
  const productRows = (products || []).filter((product) => !wantedSku || String(product.sku || "").toUpperCase() === wantedSku);
  if (!productRows.length) return { folderId: "product-images", rows: [] };
  const productIds = productRows.map((product) => String(product.id));
  const { data: images, error: imageError } = await service
    .from("product_images")
    .select("id,product_id,storage_path,file_name,mime_type,fingerprint,created_at")
    .eq("organization_id", caller.membership.organizationId)
    .eq("is_primary", true)
    .in("product_id", productIds);
  if (imageError) {
    console.error("product image library metadata lookup failed", imageError.message);
    throw new ApiError("SERVER", "Could not load the product image library. Please retry.", 500);
  }
  const byProduct = new Map((images || []).map((image) => [String(image.product_id), image]));
  const rows: Record<string, unknown>[] = [];
  for (const product of productRows) {
    const image = byProduct.get(String(product.id));
    if (!image) continue;
    const signed = await service.storage.from("product-images").createSignedUrl(String(image.storage_path), 300);
    if (signed.error) {
      console.error("product image signed URL failed", signed.error.message);
      continue;
    }
    rows.push(imageProductShape(product as Record<string, unknown>, {
      fileId: String(image.id || ""),
      name: String(image.file_name || ""),
      fingerprint: String(image.fingerprint || ""),
      updatedAt: String(image.created_at || ""),
      url: signed.data?.signedUrl || "",
    }));
  }
  return { folderId: "product-images", rows };
}

function recognitionWords(value: unknown): string[] {
  return String(value || "").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim().split(/\s+/).filter((word) => word.length > 1);
}

async function recognizeProductImage(caller: Caller, request: RequestEnvelope): Promise<Json> {
  const service = serviceClient();
  const { data: products, error: productError } = await service
    .from("products")
    .select("id,sku,name,category,unit,selling_price,kind")
    .eq("organization_id", caller.membership.organizationId)
    .eq("active", true);
  if (productError) {
    console.error("product image recognition product lookup failed", productError.message);
    throw new ApiError("SERVER", "Could not search the product catalogue. Please retry.", 500);
  }
  let fingerprint = optionalText(request.fingerprint)?.toLowerCase() || "";
  if (imageDataValue(request)) fingerprint = (await readImageBytes(request)).fingerprint;
  const productRows = products || [];
  const productIds = productRows.map((product) => String(product.id));
  const { data: images, error: imageError } = productIds.length
    ? await service.from("product_images").select("product_id,fingerprint,file_name").eq("organization_id", caller.membership.organizationId).eq("is_primary", true).in("product_id", productIds)
    : { data: [], error: null };
  if (imageError) {
    console.error("product image recognition metadata lookup failed", imageError.message);
    throw new ApiError("SERVER", "Could not search the product catalogue. Please retry.", 500);
  }
  const imagesByProduct = new Map((images || []).map((image) => [String(image.product_id), image]));
  const barcode = optionalText(request.barcode)?.toUpperCase() || optionalText(request.sku)?.toUpperCase() || "";
  const words = new Set([
    ...recognitionWords(request.name), ...recognitionWords(request.filename),
    ...recognitionWords(request.query), ...recognitionWords(request.barcode), ...recognitionWords(request.sku),
  ]);
  const matches = productRows.map((product) => {
    const image = imagesByProduct.get(String(product.id));
    let score = 0;
    const reason: string[] = [];
    if (fingerprint && String(image?.fingerprint || "").toLowerCase() === fingerprint) { score += 100; reason.push("same saved image"); }
    if (barcode && String(product.sku || "").toUpperCase() === barcode) { score += 95; reason.push("SKU or barcode"); }
    const productWords = new Set([
      ...recognitionWords(product.name), ...recognitionWords(product.sku), ...recognitionWords(image?.file_name),
    ]);
    const overlap = Array.from(productWords).filter((word) => words.has(word)).length;
    if (overlap) { score += Math.min(45, overlap * 12); reason.push("catalogue text"); }
    return { score, reason: reason.join(", ") || "catalogue text", product: imageProductShape(product as Record<string, unknown>, {}) };
  }).filter((match) => match.score > 0).sort((left, right) => right.score - left.score || String((left.product as Record<string, unknown>).name).localeCompare(String((right.product as Record<string, unknown>).name))).slice(0, 8);
  const best = matches[0];
  return {
    matches,
    product: best?.product || null,
    sku: best ? String((best.product as Record<string, unknown>).sku || "") : "",
    name: best ? String((best.product as Record<string, unknown>).name || "") : "",
    confidence: best ? Math.min(1, Math.round(best.score) / 100) : 0,
    mode: "catalog",
    labels: [],
    message: best
      ? "Matched against the saved product catalogue (SKU, saved-image fingerprint, or catalogue text)."
      : "No confident catalogue match. Select a product manually or prepare a new one for owner review.",
    suggestedProduct: best ? null : {
      sku: barcode,
      name: String(request.name || request.filename || "").replace(/\.[A-Za-z0-9]{1,8}$/, "").slice(0, 80),
    },
  };
}

function productImportTemplate(): Json {
  return {
    fileName: "cashbook-product-template.csv",
    mimeType: "text/csv",
    csv: "SKU,Name,Category,Unit,SellingPrice,ReorderLevel,Type\nSKU001,Example item,General,pc,0,0,ITEM\n",
    instructions: "Save this CSV on the device when offline. Complete one product per row, then upload it in Products & services when online. Review the preview before saving.",
  };
}

function visionStatus(): Json {
  return {
    enabled: false,
    provider: "Catalog and barcode matching",
    folderId: "product-images",
    message: "Private Supabase Storage and catalogue matching are active. External AI labels are not enabled until an approved provider and secret are deployed.",
  };
}

async function dispatch(httpRequest: Request, request: RequestEnvelope): Promise<Json> {
  const action = actionOf(request);
  if (action === "login") return await login(request);

  const caller = await callerFor(httpRequest, request);
  requireOwner(caller, action);
  switch (action) {
    case "logout":
      // This revokes the session's refresh token. The short-lived access JWT
      // may remain valid until expiry, so sensitive server operations still
      // verify membership on every command.
      await caller.client.auth.signOut({ scope: "local" });
      return { loggedOut: true };
    case "changePin":
      return await changePin(caller, request);
    case "snapshot":
    case "refresh":
      return await snapshot(caller, request);
    case "batch":
      return await batch(caller, request);
    case "lists":
    case "products":
    case "parties":
    case "ledger":
    case "statement":
    case "stockCard":
    case "report":
    case "attention":
    case "audit":
    case "users":
    case "config":
    case "previewProducts":
    case "previewOpeningStock":
      return await readAction(caller, action, request);
    case "dashboard":
      return await dashboard(caller, request);
    case "importProducts":
      return await importProducts(caller, request);
    case "importOpeningStock":
      return await importOpeningStock(caller, request);
    case "saveProduct":
      return await saveProduct(caller, request);
    case "saveProductImage":
      return await saveProductImage(caller, request);
    case "imageLibrary":
      return await imageLibrary(caller, request);
    case "recognizeProductImage":
      return await recognizeProductImage(caller, request);
    case "productImportTemplate":
      return productImportTemplate();
    case "visionStatus":
      return visionStatus();
    case "resetPurchaseCosts":
      return await resetPurchaseCosts(caller, request);
    case "saveParty":
      return await saveParty(caller, request);
    case "saveUser":
      return await saveUser(caller, request);
    case "resetPin":
      return await resetPin(caller, request);
    case "whatsAppRecipients":
      return await whatsAppRecipients(caller);
    case "saveWhatsAppRecipients":
      return await saveWhatsAppRecipients(caller, request);
    case "saveLocation":
      return await saveLocation(caller, request);
    case "saveConfig":
      return await saveConfig(caller, request);
    case "closePeriod":
      return await closePeriod(caller, request);
    case "resolveAttention":
      return await resolveAttention(caller, request);
    case "ackAttention":
      return await acknowledgeAllAttention(caller, request);
    case "integrity":
      return await integrity(caller);
    case "resetPreview":
      return await resetPreview(caller);
    case "backup":
      return migrationRequired("On-demand backup download");
    case "recalc":
      return await recalculateReadModels(caller);
    case "factoryReset":
      return migrationRequired("Permanent data deletion");
    case "sync":
      return await sync(caller, request);
    case "entry": {
      const entry = request.entry && typeof request.entry === "object" && !Array.isArray(request.entry)
        ? request.entry as Record<string, unknown> : {};
      return await postEntry(caller, entry);
    }
    default:
      throw new ApiError("MIGRATION_PENDING", `The ${action} action has not moved to Supabase yet. Continue using the existing app for this task until its migration phase is approved.`, 409);
  }
}

Deno.serve(async (request) => {
  let cors: HeadersInit = {};
  try {
    cors = corsFor(request);
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors });
    if (request.method === "GET" && new URL(request.url).searchParams.has("ping")) {
      return json({ ok: true, app: "cashbook", backend: "supabase", time: new Date().toISOString() }, 200, cors);
    }
    if (request.method !== "POST") throw new ApiError("BAD_REQUEST", "Use POST for Cashbook commands.", 405);
    const envelope = await readEnvelope(request);
    return json({ ok: true, data: await dispatch(request, envelope) }, 200, cors);
  } catch (error) {
    const out = apiError(error);
    return json({ ok: false, code: out.code, error: out.error }, out.status, cors);
  }
});
