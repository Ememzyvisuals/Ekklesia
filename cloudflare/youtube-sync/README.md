# YouTube Sync — Cloudflare Worker

One of three Workers closing out Blaze avoidance entirely (see
`cloudflare/daily-content/README.md` for the other two — daily
verse/prayer + cleanup). Same job `functions/src/youtubeSync.ts` does —
pull DCLM's uploads/live status from YouTube Data API v3, write to
Firestore — running on Cloudflare Workers, **plus** the live-status push
notification that used to be `onLiveStatusChanged` (a Firestore trigger,
folded in here — see `youtube.ts`'s `syncYoutube` and `fcm.ts`).

## Why this one is riskier than the Groq proxy

The Groq proxy (`cloudflare/groq-proxy/`) only ever *reads* — it forwards
a chat request to Groq and returns the reply, no Firestore access needed.
This Worker needs to **write** to Firestore, and `firestore.rules`
deliberately blocks client writes to `youtube_videos`/`config` (server
only — see that file's comment). Keeping that security boundary intact
while moving the actual sync off Firebase means this Worker needs real
admin-level Firestore access — which means a Google Service Account,
which means hand-rolling that service account's OAuth2 flow using only
Web Crypto (`firestoreClient.ts`), since there's no `firebase-admin` for
Workers. That file's own doc comment flags it as the highest-risk,
least-conventional piece of this entire project. Test it deliberately
before trusting the sync jobs that depend on it.

## Setup

### 1. Create a Service Account

In Google Cloud Console (same project as your Firebase project):
1. IAM & Admin → Service Accounts → Create Service Account.
2. Grant it the **Cloud Datastore User** role (not project-wide Editor —
   this is the minimum role that can read/write Firestore) **and**
   **Firebase Cloud Messaging API Admin** — added in this pass so this
   Worker can send the live-status push itself (`fcm.ts`) instead of
   needing `onLiveStatusChanged`, a Firestore trigger Workers doesn't
   have. If you deployed this Worker before this pass with only the
   Datastore role, add the messaging role now or live notifications will
   silently fail (logged, but never thrown — see `index.ts`'s
   `notifyLiveTransition`).
3. Create a JSON key for it, download it.

### 2. Set secrets

```bash
cd cloudflare/youtube-sync
npm install
npx wrangler login

npm run secret:youtube
# paste your YouTube Data API v3 key

npm run secret:service-account
# paste the ENTIRE downloaded JSON key file contents as one string
```

Edit `wrangler.toml`'s `FIREBASE_PROJECT_ID` to your real project ID.

### 3. Deploy

```bash
npm run deploy
```

This registers the Cron Trigger (every 15 minutes, same as the Cloud
Function version) automatically — no separate scheduler setup needed,
unlike Firebase's Cloud Scheduler.

Note the printed Worker URL
(`https://ekklesia-youtube-sync.<subdomain>.workers.dev`) — put it in
`app_config.dart`'s `youtubeSyncProxyBaseUrl`.

## Testing before relying on the schedule

```bash
npm run dev
```

Then trigger the HTTP path manually (needs a real Firebase ID token —
grab one from a signed-in app session via `AuthService.instance.getIdToken()`
temporarily logged, or Firebase's own token-testing tools):

```bash
curl -X POST http://localhost:8787/syncNow \
  -H "Authorization: Bearer <a real Firebase ID token>"
```

Check the response and your Firestore console's `youtube_videos`
collection for new/updated documents before trusting the cron schedule.

```bash
npm run tail
```

Streams live logs — check this after the first real scheduled run fires
(within 15 minutes of deploy) to confirm it actually succeeded, not just
that `wrangler deploy` didn't error.

## What this does NOT change

- `firestore.rules` — untouched. `youtube_videos`/`config` writes are
  still server-only; this Worker satisfies that by using real service
  account credentials, not by relaxing the rule.
- The client's read path (`YoutubeRepository.getCachedUploads()`,
  `watchLiveStatus()`) — unchanged, still reads Firestore directly via
  the Firebase SDK. Only the *write* path (`refresh()` / the schedule)
  moved.
- `functions/src/youtubeSync.ts` is left in place, not deleted, for the
  same reason `groqProxy.ts` was left in place — in case you'd rather run
  that instead, or roll back.

## Honest limitations

- Not deployed or tested against a real Cloudflare account, real GCP
  service account, or real Firestore project — see `firestoreClient.ts`'s
  doc comment. This is the single highest-risk untested component in
  this whole project as of this pass.
- No batching on the Firestore writes (REST API doesn't have the same
  convenient batch-write helper `firebase-admin`'s SDK does) — writes up
  to 25 video documents sequentially per sync. Fine at this scale
  (bounded by `maxResults=25`), would need revisiting if that ever grows.
- The live-status push fan-out (`fcm.ts`) loops one FCM request per
  device token and hits the Workers Free plan's 50-subrequest-per-
  invocation cap at scale — same ceiling and same tradeoff options
  documented in `cloudflare/daily-content/README.md`, since it's the
  identical `fcm.ts` pattern reused here.
