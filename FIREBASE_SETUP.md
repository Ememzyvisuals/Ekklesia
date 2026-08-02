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
5. Upgrade to the **Blaze (pay-as-you-go)** plan — Cloud Functions and
   Cloud Scheduler both require it, even if you stay within the free
   tier's usage limits.

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
| `dailyVerseSchedule` | Scheduled | Picks + stores today's verse |
| `dailyPrayerSchedule` | Scheduled | Generates today's prayer from the verse via Groq |
| `youtubeSyncSchedule` | Scheduled (15 min) | Pulls YouTube uploads/live status into Firestore |
| `syncYoutubeNow` | Callable | Manual trigger — `YoutubeRepository.refresh()` calls this |
| `groqChat` | Callable | Chat proxy — `GroqService.chat()` calls this |
| `groqModels` | Callable | Live model list — `AIConfig.verify()` calls this |
| `cleanupSchedule` | Scheduled | Server-side log/notification pruning (client also has `CleanupWorker` for local housekeeping) |
| notification triggers | Firestore-triggered | Fan out push notifications on relevant writes |

## 7. Verify

- `firebase functions:log` — tail logs after a deploy to confirm each
  scheduled function actually fires on its first scheduled run.
- Sign in from the app, open the AI Assistant, send a message — this
  exercises `groqChat` end-to-end. If it fails, check
  `firebase functions:log` for the specific error (missing secret,
  malformed request, etc.) before assuming the client code is wrong.
- Open Sermons and pull-to-refresh — exercises `syncYoutubeNow`.

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
