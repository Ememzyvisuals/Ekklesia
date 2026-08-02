# Groq Proxy — Cloudflare Worker

Hides `GROQ_API_KEY` from the client, same job `functions/src/groqProxy.ts`
does on Firebase — deployed on Cloudflare Workers instead, specifically
so this piece doesn't require the Firebase Blaze plan.

## Why Cloudflare Workers instead of Firebase Cloud Functions (checked, not guessed)

Firebase Cloud Functions — even a single lightweight callable — requires
the **Blaze (pay-as-you-go) plan**, which requires a payment method on
file even if actual usage stays at $0 within the free tier. That's the
concrete thing this migration avoids.

Verified current (2026) Cloudflare Workers free tier: **100,000
requests/day, no credit card required to sign up or to use the free
tier**. Comfortably covers this app's AI chat traffic — the 20/day
per-device cap already in `GroqUsageService` means even a fairly large
user base stays well under 100k/day in aggregate.

## What this does NOT change

- **YouTube sync (`syncYoutubeNow`/`youtubeSyncSchedule`) is still on
  Firebase Cloud Functions** — this migration was scoped to Groq
  specifically. If avoiding Blaze entirely (not just for Groq) matters,
  that one would need the same treatment — it's a very similar shape
  (Cloudflare Cron Triggers for the schedule, a Worker endpoint for the
  on-demand callable) but wasn't done here since it wasn't asked for.
  Note this means **Blaze may still be required** for this app overall
  unless YouTube sync is migrated too, or moved client-side again with
  its own key-exposure tradeoff, or dropped.
- Firebase Auth, Firestore, and everything else about this app's backend
  is untouched — this Worker only replaces the two Groq-related
  callables (`groqChat`, `groqModels`).
- `functions/src/groqProxy.ts` and `functions/src/groq.ts` are left in
  place in the Firebase Functions codebase (not deleted) in case you'd
  rather run both / roll back — but the Flutter client (`groq_service.dart`,
  `ai_config.dart`) now points at this Worker, not that Cloud Function.

## Auth model — how this stays secure without Firebase's callable auth

Firebase Cloud Function callables get `request.auth` for free from the
Firebase SDK. A plain Cloudflare Worker doesn't — so this Worker verifies
the caller's Firebase ID token itself: fetches Google's public JWKS for
Firebase, checks the RS256 signature, `iss`
(`https://securetoken.google.com/{projectId}`), `aud` (your project ID),
and standard expiry — the same checks Firebase's own Admin SDK does
server-side. A request without a valid, current ID token for *your*
Firebase project is rejected (401) before the Groq key is ever touched.

The Flutter client sends this token as `Authorization: Bearer <token>`
via `AuthService.instance.getIdToken()` — see `groq_service.dart`.

## Deploy

```bash
cd cloudflare/groq-proxy
npm install
npx wrangler login          # one-time, opens a browser — no card needed
```

Edit `wrangler.toml`'s `FIREBASE_PROJECT_ID` to your real project ID
(find it in the Firebase console — it's not a secret, it's already in
your app's `google-services.json`/`GoogleService-Info.plist`).

```bash
npm run secret:groq         # paste your Groq API key when prompted
npm run deploy
```

This prints your Worker's URL, something like
`https://ekklesia-groq-proxy.<your-subdomain>.workers.dev`. Put that in
`lib/core/config/app_config.dart`'s `groqProxyBaseUrl` (see that file —
this pass added the constant but left a placeholder value, since the
real URL only exists after your first `wrangler deploy`).

## Local testing

```bash
npm run dev
```

Runs the Worker locally via `wrangler dev` (real Cloudflare runtime
emulation, not just a Node HTTP server) — point `app_config.dart`'s
`groqProxyBaseUrl` at the printed `localhost` URL temporarily to test
end-to-end against a real device/emulator before deploying.

## Logs

```bash
npm run tail
```

Streams live request logs — the equivalent of `firebase functions:log`
for this Worker. Useful for the same class of debugging
`TtsErrorLogger` exists for on the TTS side: seeing *why* a request
failed (bad token, Groq rate limit, malformed body) instead of just that
it failed.

## Honest limitations of this pass

- **Not deployed or tested against a live Cloudflare account** — same
  caveat as everything else in this project that touches a real external
  service (see `FINAL_AUDIT_REPORT.md`). The code is real, reasoned
  through, and follows Cloudflare's documented Workers + `jose` JWT
  verification patterns, but "compiles and reasons correctly" isn't the
  same as "confirmed working."
- No rate limiting/abuse protection at the Worker level beyond the
  client's own `GroqUsageService` cap — a modified client could still
  hammer this Worker with valid tokens. Consider Cloudflare's own rate
  limiting rules (free tier includes basic ones) if this becomes a real
  concern.
