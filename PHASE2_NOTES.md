# Phase 2 — Cloud Functions backend

Adds the server-side half of the spec's "Flutter -> Firebase Auth -> Cloud
Functions -> External APIs -> Firestore -> Flutter" architecture. Everything
below is real, type-checked TypeScript (`npx tsc --noEmit` passes clean,
`npm run build` produces working `lib/`) — not scaffolding.

## What's here

| Function | Trigger | Does |
|---|---|---|
| `dailyVerseSchedule` | Cloud Scheduler, 00:05 Africa/Lagos daily | Picks today's reference, fetches English text from wldeh's CDN, writes `daily_verse/{yyyy-MM-dd}` |
| `dailyPrayerSchedule` | Cloud Scheduler, 00:10 Africa/Lagos daily | Reads today's verse, asks Groq for a short prayer, writes `daily_prayer/{yyyy-MM-dd}` |
| `youtubeSyncSchedule` | Cloud Scheduler, every 15 min | Mirrors `YoutubeRepository.refresh()` server-side — writes `youtube_videos/*` and `config/youtube_live_status` |
| `groqChat` / `groqModels` | ~~Callable~~ **Superseded** — see below | These still exist in `functions/src/groqProxy.ts` but the client no longer calls them; moved to a Cloudflare Worker (`cloudflare/groq-proxy/`) this pass |
| `onDailyVerseCreated` / `onDailyPrayerCreated` / `onLiveStatusChanged` | Firestore triggers | Fan out FCM pushes + write per-user `notifications` docs |
| `cleanupSchedule` | Cloud Scheduler, every 24h | Prunes `notifications`/`worker_logs`/`sync_logs`/`download_logs` across **all** users (client-side `CleanupWorker` only ever prunes whoever's currently signed in on that device) |
| `generateTodaysVerseNow` / `syncYoutubeNow` | Callable | Manual triggers for testing without waiting on the schedule |

`src/config.ts` mirrors `app_config.dart`'s collection name constants by hand
— there's no cross-language codegen in this repo, so if you rename a
collection in `app_config.dart`, update `functions/src/config.ts` in the
same commit.

## Groq key-exposure fix — DONE (client-side, an earlier pass)

**Superseded by the Cloudflare migration below** — kept here as history
of how the key-exposure problem was first closed, before moving off
Firebase Cloud Functions entirely for this specific piece.

`groq_service.dart` and `ai_config.dart` used to call the
`groqChat`/`groqModels` callables via `cloud_functions` instead of
holding `GROQ_API_KEY` through `flutter_dotenv`. `GROQ_API_KEY` was
removed from `.env.example` at that point — it never went back in.

## Groq moved off Firebase entirely — Cloudflare Workers (this pass)

`groqChat`/`groqModels` are no longer called by the client at all.
`GroqService`/`AIConfig` now call a Cloudflare Worker
(`cloudflare/groq-proxy/`) instead — same job (hide the Groq key,
verify the caller is a real signed-in user), different host, because
Firebase Cloud Functions require the Blaze plan (a payment method on
file) even for a single lightweight callable, and Cloudflare Workers'
free tier needs none. See `cloudflare/groq-proxy/README.md` for the
full reasoning, verified current free-tier numbers, and deploy steps.

**`functions/src/groqProxy.ts` and `functions/src/groq.ts` are left in
place, unexported changes** — not deleted, in case you'd rather run both
or roll back, but nothing in the Flutter client calls them anymore.

**YouTube sync has ALSO now moved off Firebase this same pass** (see the
next section) — see that section for the honest remaining-Blaze-surface
caveat.

## YouTube sync also moved off Firebase — Cloudflare Workers (this pass)

Same reasoning as Groq above. `YoutubeRepository.refresh()` now calls
`cloudflare/youtube-sync/`'s `/syncNow` endpoint instead of the
`syncYoutubeNow` callable. That Worker also handles the 15-minute
schedule itself via a Cloudflare Cron Trigger, replacing
`youtubeSyncSchedule`. It writes to Firestore using a real Google
Service Account (not by relaxing `firestore.rules`) — see
`cloudflare/youtube-sync/README.md`, which also flags this as the
riskiest, least-conventional piece of the whole project (hand-rolled
service-account OAuth2 in a Workers runtime, untested against a real
account).

**`cloud_functions` is now a fully unused dependency and was removed
from `pubspec.yaml`** — nothing in the Flutter client calls any Firebase
callable anymore.

## Important honesty check: this does NOT mean Blaze is avoidable yet

Migrating Groq and YouTube sync closes the two things actually asked
about, but **`functions/src/index.ts` still exports four other things
that require Cloud Functions (and therefore Blaze) if deployed**:

- `dailyVerseSchedule`, `dailyPrayerSchedule` — daily content generation
- `cleanupSchedule` — server-side log pruning
- `onDailyVerseCreated`/`onDailyPrayerCreated`/`onLiveStatusChanged` —
  push notification fan-out (Firestore-triggered)

If the goal is avoiding Blaze **completely**, the honest path is:
**don't deploy `functions/` at all.** Here's what that actually costs,
feature by feature:

- Daily verse/prayer: fine — `VerseWorker`/`PrayerWorker` already
  generate them client-side as a fallback if the Firestore doc is
  missing (originally built as a same-session fallback for a missed
  scheduled run, but works identically as the *only* source if the
  schedule never runs at all).
- Cleanup: fine — the client's `CleanupWorker` already does local/
  per-user housekeeping independently.
- **Push notifications for new verse/prayer/live status: lost, with no
  equivalent built.** This is the one piece with no client-side
  fallback, because by nature it needs something server-side reacting
  to *any* user's data change to notify *other* users — a Cloudflare
  Worker with a Cron Trigger could poll for changes instead of reacting
  to a Firestore trigger directly, but that's a different architecture,
  not built this pass since it wasn't asked for.

Firebase itself (Auth, Firestore, Storage, Cloud Messaging, Analytics,
Crashlytics) stays on the **free Spark plan** either way — none of those
require Blaze or a payment method. Only Cloud Functions does. So "avoid
Blaze" = "don't deploy `functions/`," not "don't use Firebase at all."



The shared Groq proxy (Cloudflare Worker now, not a Firebase callable —
see above) has a soft daily cap
(`GroqUsageService.dailyFreeLimit = 20`, local SharedPreferences counter,
not server-enforced — see that class's doc comment for why) to protect
the shared Groq key's daily quota from being exhausted by heavy users.
Once hit, `GroqService.chat()` throws `GroqUsageLimitException` **without
making a network call**, and the AI Assistant screen shows an actionable
message with a shortcut to Settings.

Settings → AI Assistant now has a "Your own Groq API key" field
(`UserGroqKeyService`, SharedPreferences). When set, `GroqService.chat()`
calls Groq directly with the user's own key instead of the shared
callable — unlimited, doesn't touch the daily counter. This is NOT a
regression on the key-exposure fix above: a personal key is the user's
own revocable credential that they typed in themselves, not a shared
secret shipped to every install.



- (Both the Groq and YouTube client-side key-exposure fixes, previously
  documented here as not-yet-done, are now done. `YoutubeRepository.refresh()`
  calls `syncYoutubeNow` instead of the deleted `YoutubeRemoteDatasource`;
  `YOUTUBE_API_KEY` is out of `.env.example`, same as `GROQ_API_KEY`. Same
  caveat applies: not tested end-to-end against a live deployed backend.)
- **Doesn't add `firebase_functions` region/App Check config** — every
  function is pinned to `us-central1` explicitly; change that if you
  provision the Firebase project in a different region.

## Setup

```bash
cd functions
npm install
```

Set secrets (never commit these — they're Secret Manager values, not `.env`):

```bash
firebase functions:secrets:set GROQ_API_KEY
firebase functions:secrets:set YOUTUBE_API_KEY
```

Deploy:

```bash
firebase deploy --only functions,firestore:rules,firestore:indexes
```

## Firestore rules (`firestore.rules`)

Default-deny, then opt in per collection:
- `users/{uid}`, `ai_conversations/*`, `notifications/*`, `sync_logs/*`:
  owner-only (matched against the doc's stored `uid` field, not just
  inferred from the path, so a crafted doc id can't spoof another user).
- `daily_verse`, `daily_prayer`, `programs`, `youtube_videos`, `config/*`,
  `feature_flags`: read-only for signed-in users. `daily_verse`/
  `daily_prayer` additionally allow **create** (not update) so
  `VerseWorker`/`PrayerWorker`'s client-side fallback-generation path
  still works if a Cloud Function run is ever missed — it can create
  today's doc if one doesn't exist yet, but can never overwrite what the
  Cloud Function already wrote.
- `worker_logs`, `download_logs`: create-only for signed-in users, no
  client read (operational data) — pruned server-side by `cleanupSchedule`.

## Firestore indexes (`firestore.indexes.json`)

Composite indexes for every multi-field query found in the repositories:
`ai_conversations` (uid+session_id+created_at, uid+created_at),
`notifications` (uid+created_at both directions), `youtube_videos`
(category+published_at).
