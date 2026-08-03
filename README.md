# EKKLESIA

Multilingual church companion app (English, Yoruba, Hausa, Igbo, Nigerian
Pidgin) — Bible, sermons/radio, AI assistant, and daily devotionals — built
with Flutter + Firebase, brand EMEMZYVISUALS DIGITALS.

> **Status: pre-release, actively built across multiple sessions.** This
> README describes what's actually in the repository today, not the full
> target spec. See "What's not done yet" below before assuming a feature
> is complete. `FINAL_AUDIT_REPORT.md` has the full ledger.

## Stack

- **Client**: Flutter, Riverpod, GoRouter, Isar (offline storage), just_audio.
- **Backend**: Firebase (Auth, Firestore, Storage, Cloud Messaging,
  Analytics, Crashlytics) on the free Spark plan, plus three Cloudflare
  Workers (TypeScript, `cloudflare/`) doing everything that would
  otherwise need Cloud Functions — Groq proxying, YouTube sync, and daily
  verse/prayer generation + cleanup + all push-notification fan-out.
  Client-facing API keys never touch the app; Groq/YouTube keys live in
  each Worker's secret store and are called over plain HTTPS with a
  Firebase ID token for auth (`groqProxyBaseUrl`,
  `youtubeSyncProxyBaseUrl` in `app_config.dart`). Moved off the
  equivalent Firebase Cloud Functions (`groqChat`, `groqModels`,
  `syncYoutubeNow`, `dailyVerseSchedule`, `dailyPrayerSchedule`,
  `cleanupSchedule`, and three Firestore-triggered notification
  functions) specifically to avoid requiring the Blaze plan — see
  `PHASE2_NOTES.md`. As of this pass, `functions/` genuinely never
  needs to be deployed; it's kept in the repo only as a rollback option.
- **AI**: Groq (chat, sermon summaries, quiz generation).
- **TTS**: HuggingFace Space (WazobiaVoice) for Bible chapter read-aloud,
  with generated audio cached to local disk so a chapter never regenerates
  on repeat plays.

## Repository layout

```
lib/
  core/            App-wide config, services (auth, tts, audio, workers), shared Result type
  features/
    bible/         Offline Bible engine — Isar-backed, see BIBLE_IMPORT_NOTES.md
    sermons/       YouTube-synced sermon library + radio
    ai/            Groq-backed chat assistant, conversation history
    bookmarks/     Cross-feature bookmarking (Bible verses, sermons, AI conversations)
    downloads/     Download queue/manager
    search/        Federated search across Bible/sermons/bookmarks/downloads/AI/settings
    notifications/ In-app notification center
    settings/, profile/, onboarding/, auth/, home/, learn/, games/
functions/src/     Cloud Functions source — fully superseded by
                   cloudflare/ (see below), kept as an optional rollback
                   path, not deployed or called by the client
cloudflare/        groq-proxy/, youtube-sync/, daily-content/ Workers —
                   fully supersede functions/; nothing calls functions/
                   anymore (kept as an optional rollback path)
assets/bible/      Bundled per-language Bible datasets (en/yo/ha/ig/pcm JSON + manifest)
tools/             build_bible.py — regenerates assets/bible/*.json from raw sources
```

## Setup

1. **Flutter dependencies**
   ```
   flutter pub get
   ```
2. **Generate Isar's `.g.dart` files** — required before anything compiles;
   this repo was built in a sandbox with no Flutter SDK, so these were
   never generated:
   ```
   flutter pub run build_runner build --delete-conflicting-outputs
   ```
3. **Firebase** — see `FIREBASE_SETUP.md` for the full walkthrough
   (project creation, `flutterfire configure`, Secret Manager keys,
   deploying rules/functions).
4. **Environment** — copy `.env.example` to `.env` and fill in what's
   still client-side (`HF_TOKEN` if the TTS Space ever goes private).
   `GROQ_API_KEY` and `YOUTUBE_API_KEY` are **not** set here anymore —
   they go into Firebase Secret Manager (see the comments in
   `.env.example` and `PHASE2_NOTES.md`).
5. **Run**
   ```
   flutter run
   ```

## What's actually done

- Home (live verse/prayer/program cards), Bible (offline, all 5
  languages — reading, search, highlights, notes, bookmarks, continue
  reading, chapter listen with local audio caching), AI Assistant (Groq
  chat via Cloudflare Worker, persisted conversations), Downloads,
  Notifications, Bookmarks, federated Search, Settings, Radio (DCLM
  stream), Sermons (YouTube-synced via Cloudflare Worker).
- 9 background-style workers wired: Sync, Youtube, Program, Verse,
  Prayer, Notification, Conversation, Cleanup, Download.
- Cloudflare Workers (3, all free-tier, no Blaze anywhere): Groq
  chat/model-list proxy; YouTube sync (on-demand `/syncNow` + its own
  15-min Cron Trigger, plus live-status push notifications folded in);
  daily verse/prayer generation + cleanup (3 Cron Triggers) with push
  notifications folded into the same write. `functions/` (Cloud
  Functions) is fully superseded and optional — kept only as a rollback
  path, see PHASE2_NOTES.md.
- Localization: 5 languages (en/yo/ha/ig/pcm), wired into 6+ screens.
- CI: 6 GitHub Actions workflows (analyze, test, dependency check,
  security scan, release).

## What's not done yet

- **Android/iOS platform folders don't exist.** Generating them requires
  a real Flutter SDK (`flutter create .`), which hasn't been available in
  the sandbox this was built in. Run that yourself once you have Flutter
  installed, then re-apply any platform-specific config from
  `DEPLOYMENT_GUIDE.md`.
- **No automated test suite** (unit/widget/repository/worker tests).
- Bible engine: no reading-streak-adjacent stats screen yet (streak is
  tracked and shown inline, but there's no dedicated stats page), no
  chunked prefetch-while-playing TTS streaming queue (chapters generate
  audio up front, then cache it — see `BIBLE_IMPORT_NOTES.md`).
- All three Cloudflare Workers (Groq proxy, YouTube sync, daily-content)
  have been migrated off Cloud Functions, but **none have been tested
  against a real deployed Worker/Firebase project** — there's no live
  deployment in this sandbox to verify against. The hand-rolled
  service-account OAuth2 flow (no `firebase-admin` on Workers) shared by
  `youtube-sync` and `daily-content` is the riskiest untested piece —
  see those Workers' README.md files.

## Docs index

- `SYSTEM_ARCHITECTURE.md` — layering, data flow, the two-storage-system split.
- `DATABASE_SCHEMA.md` — Isar collections + Firestore collections.
- `API_REFERENCE.md` — the three Cloudflare Worker endpoints (Groq,
  YouTube sync, daily content) that replaced every Cloud Function
  callable the client used to call.
- `CLOUD_FUNCTIONS.md` — full backend function inventory (all superseded).
- `WORKERS.md` — client-side workers, and which spec-named Bible workers
  were folded into existing classes instead of built separately.
- `OFFLINE_ENGINE.md` — what's actually offline-first (Bible) vs. not.
- `BIBLE_IMPORT_NOTES.md` — how the offline Bible dataset was built,
  versification handling, known anomalies.
- `LOCALIZATION_GUIDE.md` — adding strings, translation-quality caveats.
- `PHASE2_NOTES.md` — Cloud Functions backend, the Groq/YouTube key
  migrations.
- `FIREBASE_SETUP.md` — project setup and deployment steps.
- `DEPLOYMENT_GUIDE.md` — build + platform-folder generation steps.
- `ACTION_WORKFLOW.md` — numbered fresh-clone-to-submittable-build path.
- `DEVELOPER_VERIFICATION_GUIDE.md` — manual feature-by-feature checks.
- `RELEASE_CHECKLIST.md` — everything that blocks store submission.
- `CONTRIBUTING.md` — code conventions, pre-commit checklist.
- `CHANGELOG.md` — session-by-session change log.
- `FINAL_AUDIT_REPORT.md` — full done/partial/not-started ledger.
- `test/README.md` — what the test suite actually covers.
