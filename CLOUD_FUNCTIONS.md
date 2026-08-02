# Cloud Functions

Source: `functions/src/`. All deployed to `us-central1`. See
`FIREBASE_SETUP.md` for deployment steps and required secrets.

| File | Exports | Type | Purpose |
|---|---|---|---|
| `dailyVerse.ts` | `dailyVerseSchedule` | Scheduled (daily) | Picks and stores today's verse reference + English text in `daily_verse/{yyyy-MM-dd}`. |
| `dailyPrayer.ts` | `dailyPrayerSchedule` | Scheduled (daily, after verse) | Generates a short prayer from today's verse via Groq, stores in `daily_prayer/{yyyy-MM-dd}`. |
| `youtubeSync.ts` | `youtubeSyncSchedule`, `syncYoutubeNow` | Scheduled + Callable, **unused by the client as of this pass** | Still deployable — but the client now calls `cloudflare/youtube-sync/`'s `/syncNow` endpoint instead, and that Worker's own Cron Trigger replaces the schedule. Moved specifically to avoid requiring Blaze. See `PHASE2_NOTES.md`'s Blaze-avoidance honesty note — four other functions below still need Blaze if deployed. |
| `groqProxy.ts` | `groqChat`, `groqModels` | Callable, **unused by the client as of this pass** | Still deployable, still reads `GROQ_API_KEY` from Secret Manager — but `GroqService`/`AIConfig` now call a Cloudflare Worker instead (`cloudflare/groq-proxy/`), to avoid requiring the Blaze plan for this specific piece. See `PHASE2_NOTES.md`. Left in place, not deleted, in case you'd rather run this instead. |
| `groq.ts` | (internal helper) | — | Defines the `GROQ_API_KEY` secret and the actual Groq API call used by `groqProxy.ts`. |
| `bibleText.ts` | `fetchEnglishVerseText` (helper, imported by `dailyVerse.ts`) | — | Fetches a single English verse's text from the wldeh CDN server-side, for the daily-verse doc only. This is unrelated to the client's offline Bible engine (`lib/features/bible/`) — that reads from a bundled dataset, not any API. Confirmed still actively imported (not dead code) — verify this before ever assuming it's safe to remove. |
| `notifications.ts` | Firestore-triggered functions | Trigger | Fans out push notifications on relevant writes (new verse, new prayer, live program, etc.). |
| `cleanup.ts` | `cleanupSchedule` | Scheduled | Server-side pruning of old log/notification documents — the server-side counterpart to the client's `CleanupWorker`. |
| `config.ts` | shared constants | — | Region, collection names, etc. shared across function files. |
| `index.ts` | re-exports everything above | — | The actual deploy manifest — `firebase deploy --only functions` deploys whatever this file exports. |

## Client callers

| Endpoint | Called from (client) |
|---|---|
| `groqChat` (Cloudflare Worker) | `lib/core/services/groq_service.dart` → `GroqService.chat()` |
| `groqModels` (Cloudflare Worker) | `lib/core/services/ai_config.dart` → `AIConfig.verify()` |
| `syncNow` (Cloudflare Worker, `cloudflare/youtube-sync/`) | `lib/features/sermons/data/youtube_repository.dart` → `YoutubeRepository.refresh()` |

None of the Firebase Cloud Functions above are called by the client
anymore as of this pass — see `PHASE2_NOTES.md`'s honesty note on what
that does and doesn't mean for whether Blaze is actually avoidable.
| `syncYoutubeNow` | `lib/features/sermons/data/youtube_repository.dart` → `YoutubeRepository.refresh()` |

## Not yet migrated

Nothing else client-side calls an external API directly with a bundled
key at this point — the Groq and YouTube migrations (this pass) were the
two flagged in `PHASE2_NOTES.md`. If a future feature needs a new
external API, follow the same pattern: Secret Manager + callable, never a
key in `.env`/`.env.example`.
