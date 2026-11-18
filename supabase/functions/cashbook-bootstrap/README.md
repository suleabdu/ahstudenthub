# Cashbook one-time bootstrap

`cashbook-bootstrap` creates the first Supabase Auth owner and calls the
service-role-only `bootstrap_cashbook` database RPC. It is not a browser API.

Set this custom function secret before deploying it:

```text
CASHBOOK_BOOTSTRAP_SECRET=<a unique, high-entropy secret>
```

Do **not** create `SUPABASE_*` secrets yourself. Hosted Supabase functions
inject the project URL and server key. The function supports both the current
`SUPABASE_SECRET_KEYS` key map and the legacy service-role variable.

Deploy it with JWT verification disabled, then invoke it from a trusted shell:

```powershell
$secret = '<CASHBOOK_BOOTSTRAP_SECRET>'
$body = @{
  email = 'owner@example.com'
  password = 'choose-a-strong-owner-password'
  username = 'owner'
  fullName = 'Business Owner'
  businessName = 'My Business'
  businessSlug = 'my-business'
  locationName = 'Main shop'
  currencyCode = 'NGN'
  currencySymbol = '₦'
} | ConvertTo-Json

Invoke-RestMethod -Method Post `
  -Uri 'https://YOUR-PROJECT.supabase.co/functions/v1/cashbook-bootstrap' `
  -Headers @{ 'x-cashbook-bootstrap-secret' = $secret } `
  -ContentType 'application/json' -Body $body
```

Use a unique secret, store it in a password manager, and rotate/remove it
after setup. The database function refuses a second initial organisation.

Deploy it with the intended unauthenticated gateway setting (the bootstrap
secret remains mandatory):

```powershell
npx supabase@latest functions deploy cashbook-bootstrap --no-verify-jwt
```

If the call returns an error, open **Supabase Dashboard → Edge Functions →
cashbook-bootstrap → Logs** and search for the returned `reference`. Never
paste the bootstrap secret or owner password into logs, chat, or source code.
