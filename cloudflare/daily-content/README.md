# `ekklesia-daily-content` — the last piece of avoiding Blaze entirely

Closes the honesty gap `PHASE2_NOTES.md` flagged after the Groq and
YouTube-sync migrations: `dailyVerseSchedule`, `dailyPrayerSchedule`,
`cleanupSchedule`, and the notification-fan-out triggers
(`onDailyVerseCreated`, `onDailyPrayerCreated`) all required deploying
`functions/` — and therefore Blaze — even after those first two
migrations. This Worker replaces all five.

## Why this needed actual research, not just "port it to a Worker"

The YouTube-sync migration was mechanical: a scheduled function and a
callable, both doing one job each, both moved to a Cron Trigger and a
`fetch()` route. Daily verse/prayer aren't that simple, because
`onDailyVerseCreated`/`onDailyPrayerCreated` are **Firestore-triggered**
functions — a feature that exists only in the Cloud Functions runtime.
Cloudflare Workers has nothing that reacts to "a document was just
created," full stop.

The naive fix is architecting a poll: a Worker that periodically checks
whether today's verse doc's `created_at` is new, then notifies. That
adds a second cron job, a stored "have I already notified for this
doc" flag to avoid double-sends, and a race window between the write
and the poll noticing it.

The actual fix, confirmed by checking how FCM's HTTP v1 API works
(`https://firebase.google.com/docs/cloud-messaging/send-message`): it
authenticates with the exact same Service-Account OAuth2 JWT-Bearer flow
already built for Firestore REST access in `cloudflare/youtube-sync/`
(different scope —
`https://www.googleapis.com/auth/firebase.messaging` instead of
`.../auth/datastore` — same JWT-signing code otherwise). Since the code
*writing* today's verse and the code that needs to *notify about* it
were always going to run in the same Worker invocation anyway, there's
no reason to round-trip through a Firestore trigger at all — just call
`fanOutNotification` directly, right after the `set()` call succeeds.
This is genuinely simpler than the Cloud Functions version, not a
workaround forced by Workers' limitations: the "trigger" pattern only
made sense there because Cloud Functions treats "write something" and
"react to a write" as two different features by default. See
`dailyVerse.ts`/`dailyPrayer.ts` for the actual code.

The same insight applies to `onLiveStatusChanged` — see
`cloudflare/youtube-sync/src/youtube.ts` and `fcm.ts`, updated in this
same pass to detect the live-status transition inline and notify from
there, instead of needing a Firestore trigger either.

## What's here

| Job | Cron (UTC, = Africa/Lagos time) | Replaces |
|---|---|---|
| Daily verse + push | `5 23 * * *` (00:05 WAT) | `dailyVerseSchedule` + `onDailyVerseCreated` |
| Daily prayer + push | `10 23 * * *` (00:10 WAT) | `dailyPrayerSchedule` + `onDailyPrayerCreated` |
| Cleanup | `35 23 * * *` (00:35 WAT) | `cleanupSchedule` |

Africa/Lagos is UTC+1 year-round (no DST), so these UTC cron expressions
never need adjusting for a seasonal time change — unlike the equivalent
would be for a US/EU timezone.

`fetch()` also exposes `/verseNow`, `/prayerNow`, `/cleanupNow` (POST,
Firebase-ID-token-authed, same pattern as `syncNow` in
`cloudflare/youtube-sync/`) for manual testing without waiting on the
schedule — the Worker equivalent of `generateTodaysVerseNow`.

## Setup

1. **Reuse the same Service Account** from `cloudflare/youtube-sync/`'s
   setup if you already created one, but **add a role**: alongside
   "Cloud Datastore User" (for Firestore), grant **"Firebase Cloud
   Messaging API Admin"** on the same service account in IAM — Firestore
   access alone does not include messaging send permission. If you'd
   rather isolate blast radius, create a second service account instead
   and use a second `GOOGLE_SERVICE_ACCOUNT_JSON` secret; this repo
   assumes one shared account for simplicity.
2. `wrangler secret put GROQ_API_KEY` — **a second copy** of the same
   key already in `cloudflare/groq-proxy/`'s secret store. This Worker
   calls Groq directly (not through the proxy) because the proxy's auth
   model expects a signed-in user's Firebase ID token, which doesn't
   exist for a scheduled server job. Two Workers holding the same key is
   an accepted tradeoff, not an oversight.
3. `wrangler secret put GOOGLE_SERVICE_ACCOUNT_JSON` — same JSON key
   file as step 1.
4. Set `FIREBASE_PROJECT_ID` in `wrangler.toml`'s `[vars]`.
5. `npm install && npm run deploy`.

## Honest caveats — read before trusting this in production

- **Completely untested against a real deployment.** Same disclaimer as
  `cloudflare/youtube-sync/`'s README — no live Cloudflare account or
  Firebase project exists in the sandbox this was built in to verify
  against. Test each of the three jobs via their `*Now` endpoint before
  trusting the cron schedule.
- **Cron Triggers have no built-in retries.** Confirmed against
  Cloudflare's current docs while researching this: if a scheduled
  invocation throws, it's gone — the next attempt is the next scheduled
  tick (24 hours away for cleanup, next day for verse/prayer), not a
  retry. `VerseWorker`/`PrayerWorker`'s client-side fallback (see their
  own doc comments) is what actually saves this in practice for
  verse/prayer specifically — the app never blocks on this Worker having
  succeeded.
- **FCM fan-out is a per-token loop, not true multicast**, and inherits
  the Workers Free plan's 50-subrequest-per-invocation cap — see
  `fcm.ts`'s header comment for the real ceiling this hits and what to
  do about it (Paid plan, or switch to an FCM topic and accept losing
  per-user `notifications` Firestore docs). Confirmed current as of this
  pass against Cloudflare's own limits documentation.
- **Workers Free plan allows 3 Cron Triggers per Worker** — this Worker
  uses exactly 3. A 4th daily job would need the Paid plan ($5/mo) or a
  second Worker. Confirmed current as of this pass.
- Free plan Cron Trigger executions get 10ms CPU time per invocation
  (separate from network wait, which doesn't count against it) — JWT
  signing via Web Crypto is typically sub-millisecond, so this should be
  comfortable, but it's unverified against a real deployment same as
  everything else here.
