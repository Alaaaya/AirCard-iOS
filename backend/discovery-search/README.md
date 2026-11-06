# Discovery search backend

Supabase Edge Function. Deploy: `supabase functions deploy discovery-search --no-verify-jwt --project-ref <ref>`.
Secrets (names): DISCOVERY_TOKEN (random 32+ chars, same value entered in the Mirsa app), TAVILY_API_KEY or BRAVE_API_KEY.
Search provider: Tavily free tier 1,000 credits/month without card (https://docs.tavily.com/documentation/api-credits). Brave: $5 per 1,000 requests, $5 monthly credit (https://api-dashboard.search.brave.com/documentation/pricing).
Returns metadata only. Never fetches result pages, never serves files.
Test: `deno test backend/discovery-search`.
