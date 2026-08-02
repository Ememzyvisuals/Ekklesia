# API Reference

The Flutter client no longer calls any Firebase Cloud Function callable
directly — as of this pass, both external-API proxies moved to
Cloudflare Workers, specifically to avoid requiring the Firebase Blaze
plan. See `PHASE2_NOTES.md` for the full reasoning and an honest note on
what this does and doesn't mean for whether Blaze is fully avoidable
(short version: these two things, yes; four other Cloud Functions still
need it if you deploy them).

Both Workers use the same auth model: a Firebase ID token sent as
`Authorization: Bearer <token>`, verified by the Worker itself against
Google's public JWKS (a plain Worker doesn't get `request.auth` for free
the way a Firebase callable does).

## Cloudflare Worker — Groq proxy (`cloudflare/groq-proxy/`)

### `POST {groqProxyBaseUrl}/groqChat`

**Called from**: `GroqService.chat()` (`lib/core/services/groq_service.dart`)

Request:
```json
{
  "messages": [{"role": "system", "content": "..."}, {"role": "user", "content": "..."}],
  "model": "llama-3.3-70b-versatile"
}
```

Response (200): `{"reply": "..."}`. Error shape (4xx/5xx): `{"error": "..."}`.

### `GET {groqProxyBaseUrl}/groqModels`

**Called from**: `AIConfig.verify()` (`lib/core/services/ai_config.dart`)

Response (200): `{"modelIds": ["llama-3.3-70b-versatile", "..."]}`.
`AIConfig.verify()` picks the first entry in
`AppConfig.groqSupportedModels` present in this list.

### Direct-to-Groq (bring-your-own-key path)

**Called from**: `GroqService._chatWithPersonalKey()`, when a personal
key is set in Settings (`UserGroqKeyService`). Bypasses the Worker
entirely — calls `https://api.groq.com/openai/v1/chat/completions`
directly with the user's own key. Legitimate exception to "never call
external APIs directly" since it's the user's own revocable credential,
not a shared secret — see `groq_service.dart`'s doc comment.

## Cloudflare Worker — YouTube sync (`cloudflare/youtube-sync/`)

### `POST {youtubeSyncProxyBaseUrl}/syncNow`

**Called from**: `YoutubeRepository.refresh()` (`lib/features/sermons/data/youtube_repository.dart`)

Request: no body, just the auth header.

Response (200): `{"videos": <count>, "live": <bool>}`. The client
currently ignores this body and just treats a non-throwing 200 as
success, then relies on its Firestore listeners
(`getCachedUploads`/`watchLiveStatus`) to pick up the new data — same
pattern as when this was a Firebase callable.

This Worker also runs on a Cloudflare Cron Trigger every 15 minutes
(`wrangler.toml`), independent of any client being open — replacing
`youtubeSyncSchedule`. Unlike the Groq proxy, this Worker also writes to
Firestore itself (via a real Google Service Account — see
`cloudflare/youtube-sync/README.md`), since `firestore.rules` blocks
client writes to `youtube_videos`/`config` by design and this migration
didn't relax that.

## Firebase Cloud Functions — still exist, not called by the client

`functions/src/groqProxy.ts` (`groqChat`, `groqModels`) and
`functions/src/youtubeSync.ts` (`youtubeSyncSchedule`, `syncYoutubeNow`)
are left in the codebase, unexported changes — in case you'd rather run
those instead of the Cloudflare Workers, or roll back. Nothing in the
Flutter client calls them as of this pass.

`dailyVerse.ts`, `dailyPrayer.ts`, `cleanup.ts`, and `notifications.ts`
are unrelated to this migration and still require Cloud Functions
(Blaze) if deployed — see `PHASE2_NOTES.md`'s honesty note for what
each one costs if you choose not to deploy `functions/` at all.

## Error handling convention

Cloudflare Worker calls check `response.statusCode` directly rather than
catching a typed exception (there's no `FirebaseFunctionsException`
equivalent for a plain HTTP call). Both ultimately surface a plain
`Exception` (or `Result.failure(AppFailure(...))` for repositories using
the `Result<T>` pattern) up to the UI layer — see
`lib/core/shared/result.dart`'s doc comment for which services use
`Result<T>` vs. throwing directly (inconsistent by design, not yet
unified — see that file for the reasoning).
