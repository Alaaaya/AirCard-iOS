# Discovery search backend

Supabase Edge Function for a Mirsa-only project (never the Player or business projects).

Auth: the app signs in anonymously (Supabase Auth, anonymous sign-ins enabled) and sends its per-install user JWT. The function verifies it server-side. No shared token ships in the app.
Limits (schema.sql, Postgres, durable, global, all-or-nothing): per user 20/hour and 60/day, per hashed IP 60/hour, global 10/minute, 60/day, 900/month (under Tavily's 1,000 free credits).
Secrets (names): TAVILY_API_KEY (or BRAVE_API_KEY), IP_SALT (random 16+ chars). SUPABASE_* are provided.
Deploy after owner approval: apply schema.sql, then `supabase functions deploy discovery-search --no-verify-jwt --project-ref <ref>` (JWT is verified in code).
Returns metadata only. Never fetches result pages, never serves files. Test: `deno test backend/discovery-search`.
