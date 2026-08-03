/// Central place for external endpoints and non-secret config.
///
/// Actual API keys (Groq, YouTube Data API, HF tokens if ever needed
/// client-side) must NOT live here — pull them from a secure source
/// (e.g. a backend proxy or Firebase Remote Config + App Check), never
/// hardcoded into the shipped app.
class AppConfig {
  AppConfig._();

  // TTS Spaces (Gradio REST API — see each Space's "Use via API" page for
  // the exact function/endpoint names before wiring these up for real).
  static const String wazobiaVoiceSpaceUrl =
      'https://ememzyvisuals-wazobiavoice-demo.hf.space';
  static const String yarnGptSpaceUrl =
      'https://ememzyvisuals-yarngpt-demo.hf.space';

  // DCLM radio direct stream mounts — LibreTime/Airtime harbor port 8xxx per
  // language. All four (including English) confirmed live via the
  // WazobiaVoice_TTS_Scraper ffprobe test, not just page-scrape inference.
  /// Verified against DCLM's own official radio-app-v1 source (each
  /// language's .php page, e.g. yoruba.php / hausa.php / index.php for
  /// English) — not guessed or reused from a stale doc. This fixes a real
  /// bug: 'english' previously pointed at 8050/english, which is actually
  /// French's mount (8050/french, confirmed in french.php); English is
  /// 8000/live. Every other entry below matched what was already here.
  static const Map<String, String> dclmStreams = {
    'yoruba': 'https://airtime.dclm.org/radio/8060/yoruba',
    'hausa': 'https://airtime.dclm.org/radio/8070/hausa',
    'igbo': 'https://airtime.dclm.org/radio/8090/igbo',
    'english': 'https://airtime.dclm.org/radio/8000/live',
  };

  /// Additional official DCLM language streams beyond the 4 currently
  /// selectable in live_screen.dart's picker — captured here since
  /// they're verified and real, not because anything reads them yet.
  /// Wiring more languages into the picker is a UI decision for later,
  /// not assumed here. No Nigerian Pidgin stream exists on DCLM's
  /// platform (checked directly) — unrelated to the Bible feature, which
  /// *does* have a Nigerian Pidgin translation now via the offline
  /// import pipeline (see features/bible/data/bible_importer.dart).
  static const Map<String, String> dclmExtraStreams = {
    'french': 'https://airtime.dclm.org/radio/8050/french',
    'portuguese': 'https://airtime.dclm.org/radio/8110/portuguese',
    'spanish': 'https://airtime.dclm.org/radio/8100/spanish',
    'egun': 'https://airtime.dclm.org/radio/8120/egun',
    'ebira': 'https://airtime.dclm.org/radio/8125/ebira',
    'twi': 'https://airtime.dclm.org/radio/8135/twi',
    'ewe': 'https://airtime.dclm.org/radio/8140/ewe',
    'efik': 'https://airtime.dclm.org/radio/8145/efik',
    'igede': 'https://airtime.dclm.org/radio/8230/igede',
    'idoma': 'https://airtime.dclm.org/radio/8220/idoma',
    'tiv': 'https://airtime.dclm.org/radio/8240/tiv',
    'gbagyi': 'https://airtime.dclm.org/radio/8250/gbagyi',
    'igala': 'https://airtime.dclm.org/radio/8040/igala',
    // Urhobo is served from a different platform (AzuraCast, not the
    // Icecast/Airtime mounts above) per urhobo.php — different host,
    // included as-is rather than normalized to a fake matching pattern.
    'urhobo': 'https://studio.dclm.org/listen/urhobo/urhobo',
  };

  /// stat1.dclm.org's Now Playing API (AzuraCast), keyed the same as
  /// [dclmStreams] + [dclmExtraStreams] — one query gives
  /// now_playing.song.{artist,title,art} and listeners.current. Verified
  /// per-language station ids straight from each language page's own
  /// script block (e.g. nowplaying/1 for English, /2 for Yoruba, etc.).
  /// The official radio-app-v1 site polls this every 60s; RadioService
  /// mirrors that cadence rather than polling faster.
  ///
  /// Discovered inconsistency in DCLM's own source, not introduced here:
  /// tiv.php and gbagyi.php both fetch nowplaying/16 verbatim — that's
  /// either a real shared station or a copy-paste bug on DCLM's end.
  /// Left as-is (matching the official site) rather than guessing a
  /// "corrected" id with no way to verify one against the live API from
  /// here.
  static const Map<String, int> dclmNowPlayingStationIds = {
    'english': 1,
    'yoruba': 2,
    'french': 3,
    'hausa': 4,
    'igbo': 5,
    'portuguese': 6,
    'egun': 7,
    'spanish': 8,
    'ebira': 9,
    'efik': 10,
    'ewe': 11,
    'twi': 12,
    'urhobo': 13,
    'igede': 14,
    'idoma': 15,
    'gbagyi': 16,
    'tiv': 17,
    'igala': 18,
  };

  static const String dclmNowPlayingBaseUrl = 'https://stat1.dclm.org/api/nowplaying';

  static const Map<String, String> dclmPageFallback = {
    'yoruba': 'https://radio.dclm.org/yoruba',
    'hausa': 'https://radio.dclm.org/hausa',
    'igbo': 'https://radio.dclm.org/igbo',
    'english': 'https://radio.dclm.org/english',
  };

  // ---- Bible text sources ----
  // The wldeh CDN Bible API is no longer used client-side — the offline
  // Bible engine (features/bible/) reads from a local Isar database
  // populated from assets/bible/*.json via BibleImporter. Datasets are
  // keyed by short code ('en', 'yo', 'ha', 'ig', 'pcm') via
  // bible_providers.dart's kAppLanguageToBibleCode / kBibleCodeLabel maps.
  // Nigerian Pidgin DOES have a Bible-reading tab now (assets/bible/pcm.json,
  // ~31k verses) — an earlier comment here claiming no Pidgin translation
  // exists predates the read-aloud-script data this was built from.

  // Groq — chat, summaries, quiz generation. The API key lives only in
  // a Cloudflare Worker's secret store now (cloudflare/groq-proxy/),
  // migrated off the Firebase `groqChat`/`groqModels` Cloud Function
  // callables specifically to avoid requiring the Firebase Blaze plan —
  // see cloudflare/groq-proxy/README.md for the reasoning and current
  // verified free-tier numbers. The client never holds the Groq key
  // either way; only where the proxy lives changed.
  static const String groqProxyBaseUrl = 'https://ekklesia-groq-proxy.YOUR-SUBDOMAIN.workers.dev';
  // ^ Placeholder — replace with your real Worker URL after your first
  // `wrangler deploy` (cloudflare/groq-proxy/README.md). GroqService and
  // AIConfig both read this constant; nothing else needs updating.

  // YouTube sync — same reasoning as groqProxyBaseUrl above, moved off
  // Firebase Cloud Functions specifically to avoid requiring the Blaze
  // plan for this piece — see cloudflare/youtube-sync/README.md. Daily
  // verse/prayer/cleanup + all push-notification fan-out needed the same
  // treatment too (cloudflare/daily-content/, no client-facing base URL
  // here since the client never calls that Worker directly) before
  // Blaze was actually fully avoidable app-wide — see PHASE2_NOTES.md.
  static const String youtubeSyncProxyBaseUrl = 'https://ekklesia-youtube-sync.YOUR-SUBDOMAIN.workers.dev';
  // ^ Placeholder — replace after your first `wrangler deploy` there.
  // YoutubeRepository.refresh() reads this constant.

  // Model fallback chain (per user decision): 70B primary for response
  // quality, 8B-instant as the fallback if 70B is ever deprecated/unavailable
  // on the free tier. AIConfig.instance.verify() checks the live model list
  // via the Cloudflare Worker's /groqModels endpoint at startup and
  // switches automatically — see ai_config.dart.
  static const String groqPreferredModel = 'llama-3.3-70b-versatile';
  static const String groqFallbackModel = 'llama-3.1-8b-instant';
  static const List<String> groqSupportedModels = [
    groqPreferredModel,
    groqFallbackModel,
  ];

  // ---- Voice routing ----
  // WazobiaVoice handles English, Hausa, Igbo, Pidgin.
  // YarnGPT-local handles Yoruba only (WazobiaVoice's Yoruba was judged
  // weaker in testing — too fast — so Yoruba is routed to YarnGPT-local's
  // female voice instead).
  //
  // CONFIRMED against the real WazobiaVoice Space API docs:
  // api_name /synthesize takes (text, voice_name, exaggeration, cfg_weight)
  // in that exact order, and voice_name must match the dropdown's exact
  // literal string (language + gender tag included) — not a bare name.
  static const String wazobiaVoiceApiName = '/synthesize';
  static const String wazobiaVoiceCloneApiName = '/clone_voice';

  static const double wazobiaVoiceExaggeration = 0.5;
  static const double wazobiaVoiceCfgWeight = 0.5;

  static const Map<String, String> wazobiaVoicePersonaByLanguage = {
    'english': 'James (English, M)',
    'hausa': 'Hauwa (Hausa, F)',
    'igbo': 'Adaeze (Igbo, F)',
    'pidgin': 'Ngozi (Pidgin, F)',
  };

  // Chatterbox-based models (WazobiaVoice's underlying architecture — see
  // the exaggeration/cfg_weight params above) have a fixed internal
  // max-generation length. Text longer than that isn't rejected — it's
  // silently truncated/padded to a fixed-length clip (observed as a
  // constant ~40s output no matter the input length). Rather than depend
  // on the Space ever surfacing that as an error, TtsService splits long
  // text into chunks under this limit and synthesizes/plays them in
  // sequence. 350 chars is a conservative safe margin under the point
  // where truncation was observed; tighten further if clipping recurs.
  static const int wazobiaVoiceMaxChars = 350;

  static const String yarnGptLocalApiName = '/synthesize_local';
  static const String yarnGptYorubaSpeaker = 'yoruba_female1';

  // ---- YouTube (DCLM sermon library / live programs) ----
  // Channel identity verified two independent ways: dclm.org's own
  // "Official Websites & Social Handles" page (which explicitly warns about
  // fake accounts) lists the handle as youtube.com/dclmhq, and fetching
  // that channel page directly resolves to this channel ID. Do not swap
  // this for any of the many national-branch DCLM channels (Netherlands,
  // Ghana, Tanzania, New Jersey, etc. all have their own separate
  // channels) — this is the global HQ channel only.
  static const String youtubeChannelId = 'UC4zsqN5YdXfxkkdVvwNA3JA';
  static const String youtubeChannelHandle = '@DCLMHQ';

  // The client no longer calls the YouTube Data API directly —
  // YoutubeRepository.refresh() calls the `youtube-sync` Cloudflare
  // Worker's `/syncNow` endpoint (cloudflare/youtube-sync/, base URL is
  // youtubeSyncProxyBaseUrl above), which holds YOUTUBE_API_KEY in its
  // own secret store instead of Secret Manager or the app bundle.
  // Superseded the `syncYoutubeNow` Cloud Function callable this pass —
  // see PHASE2_NOTES.md. The Worker's source also documents the
  // uploads-playlist-id-from-channel-id resolution (via
  // channels.list?part=contentDetails, not the hardcoded "UC"->"UU" swap
  // trick) — same reasoning as when this lived client-side.

  // Firestore cache collection for YouTube metadata (per the addendum's
  // "use Firestore as metadata cache" rule) — never store the API key or
  // raw API responses here, only the fields actually used by the UI.
  static const String youtubeCacheCollection = 'youtube_videos';
  static const String youtubeLiveStatusDoc = 'youtube_live_status';

  // ---- Daily content (Verse/Prayer workers) ----
  // Server-authoritative once Cloud Functions + Cloud Scheduler exist
  // (see build roadmap, Phase 2); until then VerseWorker/PrayerWorker
  // generate client-side on first open of the day and write here so the
  // schema doesn't change out from under the app when the Cloud Function
  // takes over — whichever writes first for a given date "wins" and every
  // other client just reads.
  static const String dailyVerseCollection = 'daily_verse';
  static const String dailyPrayerCollection = 'daily_prayer';

  // ---- Programs (ProgramWorker) ----
  static const String programsCollection = 'programs';

  // ---- Workers / ops logging ----
  static const String workerLogsCollection = 'worker_logs';
  static const String syncLogsCollection = 'sync_logs';
  static const String downloadLogsCollection = 'download_logs';
  static const String featureFlagsCollection = 'feature_flags';

  // ---- Bookmarks (Bible / sermons / AI conversations) ----
  static const String bookmarksCollection = 'bookmarks';

  // A small built-in verse reference list used only as an offline seed /
  // last-resort fallback if VerseWorker has never successfully run for
  // today and there's no connection — NOT a replacement for real reading
  // plans (see VerseWorker doc comment).
  static const List<String> verseFallbackReferences = [
    'John 3:16',
    'Psalms 23:1',
    'Philippians 4:13',
    'Romans 8:28',
    'Proverbs 3:5-6',
    'Isaiah 41:10',
    'Jeremiah 29:11',
    'Psalms 46:1',
    'Matthew 11:28',
    '2 Corinthians 5:17',
  ];
}
