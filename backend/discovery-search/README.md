# Discovery search backend

Supabase Edge Function for a Mirsa-only project (never the Player or business projects).

Auth: the app signs in anonymously (Supabase Auth, anonymous sign-ins enabled) and sends its per-install user JWT. The function verifies it server-side. No shared token ships in the app.
Credit accounting: one request = exactly one Tavily basic search (1 credit); no retries, no multi-query. The credit is reserved atomically (global-month 900) before the provider call and never refunded, even on timeout.
IP: only cf-connecting-ip is used only when cf-ray is also present (verified empirically 2026-11-06: Cloudflare edge sets it and rejects client-supplied values with error 1000; x-forwarded-for is rewritten). Not a documented guarantee, so fall back to one shared bucket otherwise. Monthly cap is a rolling 31-day sum of global-day, 900. (platform-set was: is used; X-Forwarded-For is ignored. If absent, all such requests share one "unknown" bucket. Verify at deploy time.
App: only project URL + public publishable/anon key are configured; session refresh token is in the Keychain.
Limits (schema.sql, Postgres, durable, global, all-or-nothing): per user 20/hour and 60/day, per hashed IP 60/hour, global 10/minute, 60/day, 900/month (under Tavily's 1,000 free credits).
Secrets (names): TAVILY_API_KEY (or BRAVE_API_KEY), IP_SALT (random 16+ chars). SUPABASE_* are provided.
Deploy after owner approval: apply schema.sql, then `supabase functions deploy discovery-search --no-verify-jwt --project-ref <ref>` (JWT is verified in code).
Returns metadata only. Never fetches result pages, never serves files. Test: `deno test backend/discovery-search`.
