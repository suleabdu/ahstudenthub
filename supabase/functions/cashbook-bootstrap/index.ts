/**
 * One-time Cashbook bootstrap.
 *
 * This endpoint is intentionally separate from the browser compatibility API.
 * Run it from a trusted administrator terminal with a high-entropy setup
 * secret; never call it from either PWA or expose its secret in runtime config.
 */
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

type BootstrapInput = {
  email?: unknown;
  password?: unknown;
  username?: unknown;
  fullName?: unknown;
  businessName?: unknown;
  businessSlug?: unknown;
  locationName?: unknown;
  currencyCode?: unknown;
  currencySymbol?: unknown;
};

class BootstrapError extends Error {
  constructor(
    readonly code: string,
    message: string,
    readonly publicMessage: string,
    readonly status = 500,
  ) {
    super(message);
  }
}

function env(name: string): string {
  const value = Deno.env.get(name);
  if (!value) {
    throw new BootstrapError(
      "BOOTSTRAP_CONFIGURATION",
      `Missing ${name}.`,
      "Bootstrap is not configured correctly. Check the function secrets and deployment.",
    );
  }
  return value;
}

/**
 * Hosted Supabase functions currently expose both key styles. Prefer the
 * current JSON key map but retain the legacy service-role variable so the
 * function works on projects that have not yet moved to the new API keys.
 */
function serviceKey(): string {
  const map = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (map) {
    try {
      const parsed = JSON.parse(map) as Record<string, unknown>;
      const current = typeof parsed.default === "string" ? parsed.default.trim() : "";
      if (current) return current;
      console.warn("cashbook bootstrap: SUPABASE_SECRET_KEYS has no default key; trying legacy key");
    } catch {
      console.warn("cashbook bootstrap: could not parse SUPABASE_SECRET_KEYS; trying legacy key");
    }
  }
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim();
  if (legacy) return legacy;
  throw new BootstrapError(
    "BOOTSTRAP_CONFIGURATION",
    "No injected Supabase server key was available.",
    "Bootstrap is not configured correctly. Check the function secrets and deployment.",
  );
}

function response(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" } });
}

function text(value: unknown): string { return typeof value === "string" ? value.trim() : ""; }

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

async function removeIncompleteOwner(service: SupabaseClient, userId: string, reference: string): Promise<void> {
  const { error } = await service.auth.admin.deleteUser(userId);
  if (error) {
    console.error("cashbook bootstrap cleanup failed", JSON.stringify({ reference, message: error.message }));
  }
}

function sameSecret(actual: string, expected: string): boolean {
  const a = new TextEncoder().encode(actual);
  const b = new TextEncoder().encode(expected);
  let difference = a.length ^ b.length;
  const max = Math.max(a.length, b.length);
  for (let i = 0; i < max; i += 1) difference |= (a[i] || 0) ^ (b[i] || 0);
  return difference === 0;
}

Deno.serve(async (request) => {
  const reference = crypto.randomUUID();
  let stage = "authorize";
  let service: SupabaseClient | null = null;
  let createdUserId: string | null = null;
  let databaseInitialised = false;
  if (request.method !== "POST") return response(405, { ok: false, error: "Use POST for bootstrap." });
  try {
    const supplied = request.headers.get("x-cashbook-bootstrap-secret") || "";
    if (!sameSecret(supplied, env("CASHBOOK_BOOTSTRAP_SECRET"))) {
      return response(403, { ok: false, error: "Bootstrap authorization failed." });
    }
    stage = "read-request";
    let input: BootstrapInput;
    try {
      const parsed = await request.json();
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        return response(400, { ok: false, code: "BAD_REQUEST", error: "Bootstrap request must be a JSON object." });
      }
      input = parsed as BootstrapInput;
    } catch {
      return response(400, { ok: false, code: "BAD_REQUEST", error: "Bootstrap request must be valid JSON." });
    }
    const email = text(input.email).toLowerCase();
    const password = text(input.password);
    const username = text(input.username).toLowerCase();
    const fullName = text(input.fullName);
    const businessName = text(input.businessName);
    const businessSlug = text(input.businessSlug).toLowerCase();
    const locationName = text(input.locationName) || "Main shop";
    const currencyCode = text(input.currencyCode).toUpperCase() || "NGN";
    const currencySymbol = text(input.currencySymbol) || "₦";

    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return response(400, { ok: false, error: "Enter a valid owner email." });
    if (password.length < 8) return response(400, { ok: false, error: "Owner password must contain at least 8 characters." });
    if (!/^[a-z0-9._-]{3,80}$/.test(username)) return response(400, { ok: false, error: "Username must contain 3–80 lowercase letters, numbers, dot, dash, or underscore." });
    if (!fullName || !businessName) return response(400, { ok: false, error: "Owner name and business name are required." });
    if (!/^[a-z0-9][a-z0-9-]{1,62}$/.test(businessSlug)) return response(400, { ok: false, error: "Business slug must use lowercase letters, numbers, and dashes." });
    if (!/^[A-Z]{3}$/.test(currencyCode)) return response(400, { ok: false, error: "Currency code must be a three-letter ISO code." });

    stage = "create-owner";
    service = createClient(env("SUPABASE_URL"), serviceKey(), {
      auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
    });
    const created = await service.auth.admin.createUser({ email, password, email_confirm: true });
    if (created.error || !created.data.user) {
      console.error("bootstrap Auth user creation failed", created.error?.message);
      return response(400, { ok: false, error: "Could not create the owner login. Check whether the email already exists." });
    }

    const userId = created.data.user.id;
    createdUserId = userId;
    stage = "initialise-database";
    const { data, error } = await service.rpc("bootstrap_cashbook", {
      p_user_id: userId,
      p_email: email,
      p_username: username,
      p_display_name: fullName,
      p_organization_name: businessName,
      p_organization_slug: businessSlug,
      p_location_name: locationName,
      p_currency_code: currencyCode,
      p_currency_symbol: currencySymbol,
    });
    if (error) {
      console.error("bootstrap database setup failed", error.message);
      // Avoid retaining an unusable Auth login when the one-time organisation
      // transaction is rejected or misconfigured.
      await removeIncompleteOwner(service, userId, reference);
      return response(400, { ok: false, error: "Could not initialise the cashbook. Check migration status and bootstrap details." });
    }
    databaseInitialised = true;
    return response(201, { ok: true, data: { ...((data || {}) as Record<string, unknown>), ownerUserId: userId } });
  } catch (error) {
    if (service && createdUserId && !databaseInitialised) {
      try {
        await removeIncompleteOwner(service, createdUserId, reference);
      } catch (cleanupError) {
        console.error("cashbook bootstrap cleanup threw", JSON.stringify({ reference, message: errorMessage(cleanupError) }));
      }
    }
    const typed = error instanceof BootstrapError ? error : null;
    const code = typed?.code || "BOOTSTRAP_FAILED";
    const message = typed?.publicMessage || "Bootstrap could not complete. Check the function logs using the reference provided.";
    console.error("cashbook bootstrap error", JSON.stringify({ reference, stage, code, message: errorMessage(error) }));
    return response(typed?.status || 500, { ok: false, code, reference, error: message });
  }
});
