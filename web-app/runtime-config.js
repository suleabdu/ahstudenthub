/*
 * Runtime configuration for the static PWAs.
 *
 * The publishable Supabase key is intentionally safe to expose in a browser
 * when database RLS and the Edge Function checks are enabled. It is not a
 * service-role key and must never be replaced with one.
 *
 * Leave both values empty while using Apps Script. The complete setup guide
 * explains how to populate these only after staging validation succeeds.
 */
window.CASHBOOK_RUNTIME = Object.freeze({
  supabaseFunctionUrl: 'https://smzkmmjkiwmedbtnlteg.supabase.co/functions/v1/cashbook-api',
  supabasePublishableKey: 'sb_publishable_lDGxm8MydUT7s-Z6-SSKRw_qVDRg8VU'
});
