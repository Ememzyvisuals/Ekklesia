# Firebase Setup

Steps to get a real Firebase project behind this app. Nothing here has
been run against a live project in this sandbox — follow it once, and if
a step behaves differently than described, that's real information worth
feeding back into this file.

## 1. Create the project

1. https://console.firebase.google.com → Add project.
2. Enable **Authentication** (Email/Password — see `auth_service.dart`,
   there's no anonymous or social sign-in wired up currently).
3. Enable **Firestore** (production mode — rules are in `firestore.rules`,
   don't leave it in test mode).
4. Enable **Storage**, **Cloud Messaging**, **Analytics**, **Crashlytics**.
5. **Blaze is optional, not required.** Cloud Functions and Cloud
   Scheduler need it, but every Cloud Function in `functions/` has been
   superseded by a Cloudflare Worker (`cloudflare/`) — see step 6 below
   and `PHASE2_NOTES.md`. Skip this entirely unless you specifically want
   to run `functions/` as a rollback path instead of the Workers.

## 2. Connect the Flutter app

```
dart pub global activate flutterfire_cli
flutterfire configure
```

This generates `lib/firebase_options.dart`, which `main.dart` expects
(`Firebase.initializeApp()` uses the platform-specific options it
provides) — **it's not included in this repo** since it's tied to your
project's actual credentials.

## 3. Deploy Firestore rules and indexes

```
firebase deploy --only firestore:rules,firestore:indexes
```

`firestore.rules` and `firestore.indexes.json` already exist in the repo
root — this just pushes them to your project. Re-run this any time either
file changes.

## 4. Secrets for Cloud Functions

Both external API keys live in Secret Manager, not in any client config:

```
firebase functions:secrets:set GROQ_API_KEY
firebase functions:secrets:set YOUTUBE_API_KEY
```

You'll be prompted to paste the value. `functions/src/groq.ts` and the
YouTube sync function read these via `defineSecret` — confirm the secret
names match exactly (`GROQ_API_KEY`, `YOUTUBE_API_KEY`) or the functions
will fail to find them at deploy time.

## 5. Install and build the functions

```
cd functions
npm install
npm run build
```

`npm run build` runs `tsc` — fix any TypeScript errors here before
deploying; `firebase deploy` will also run this automatically via the
`predeploy` hook in `firebase.json`, but it's faster to catch errors
locally first.

## 6. Deploy the functions

```
firebase deploy --only functions
```

This deploys everything in `functions/src/index.ts`'s exports:

| Function | Type | Purpose |
|---|---|---|
| `dailyVerseSchedule` | Scheduled | **Superseded** — `cloudflare/daily-content/`'s `5 23 * * *` Cron Trigger does this now |
| `dailyPrayerSchedule` | Scheduled | **Superseded** — `cloudflare/daily-content/`'s `10 23 * * *` Cron Trigger does this now |
| `youtubeSyncSchedule` | Scheduled (15 min) | **Superseded** — `cloudflare/youtube-sync/`'s own Cron Trigger does this now |
| `syncYoutubeNow` | Callable | **Superseded** — `YoutubeRepository.refresh()` calls the `youtube-sync` Worker's `/syncNow` instead |
| `groqChat` | Callable | **Superseded** — `GroqService.chat()` calls the `groq-proxy` Worker instead |
| `groqModels` | Callable | **Superseded** — `AIConfig.verify()` calls the `groq-proxy` Worker's `/groqModels` instead |
| `cleanupSchedule` | Scheduled | **Superseded** — `cloudflare/daily-content/`'s `35 23 * * *` Cron Trigger does this now |
| `onDailyVerseCreated` / `onDailyPrayerCreated` | Firestore-triggered | **Superseded** — folded inline into `cloudflare/daily-content/`'s verse/prayer jobs, right after each write |
| `onLiveStatusChanged` | Firestore-triggered | **Superseded** — folded inline into `cloudflare/youtube-sync/`'s sync job |
| `generateTodaysVerseNow` | Callable | **Superseded** — `/verseNow` on the `daily-content` Worker |

Every function above is superseded — deploying `functions/` isn't
required for anything the client uses anymore. It's kept only as a
manual rollback option (e.g. if a Worker misbehaves in production and
you want a known-working fallback while you debug it). See
`PHASE2_NOTES.md` for the full migration history and honest caveats on
what's untested.

## 7. Verify

- `firebase functions:log` — only relevant if you chose to deploy
  `functions/` as a rollback path; the Workers below are what actually
  runs by default.
- Sign in from the app, open the AI Assistant, send a message — this
  exercises the `groq-proxy` Cloudflare Worker end-to-end (not
  `groqChat` anymore). If it fails, check `wrangler tail` for the
  specific error (missing secret, malformed request, etc.) before
  assuming the client code is wrong.
- Open Sermons and pull-to-refresh — exercises the `youtube-sync`
  Worker's `/syncNow` (not `syncYoutubeNow` anymore).
- `cloudflare/daily-content/` has no in-app screen to trigger it from
  (it's a scheduled/server-only job) — verify it via its `/verseNow`,
  `/prayerNow`, `/cleanupNow` endpoints directly (curl + a real Firebase
  ID token, same pattern as `youtube-sync`'s README), then check
  Firestore's `daily_verse`/`daily_prayer` collections and your own
  device's notifications for the resulting push.

## Emulators (local testing before deploying)

```
cd functions
npm run serve
```

Runs `functions` + `firestore` emulators. Point the Flutter app at them
with `FirebaseFirestore.instance.useFirestoreEmulator(...)` /
`FirebaseFunctions.instance.useFunctionsEmulator(...)` calls added
temporarily in `main.dart` — not wired in permanently since that would
accidentally point production builds at a local emulator if left in.
