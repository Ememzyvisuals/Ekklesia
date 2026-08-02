/**
 * Collection/doc names mirrored 1:1 from lib/core/config/app_config.dart.
 * Kept as a hand-synced constant file rather than a generated one — there's
 * no cross-language codegen in this repo yet. If you rename a collection
 * in app_config.dart, update this file in the same commit or the client
 * and the functions will silently diverge.
 */
export const COLLECTIONS = {
  dailyVerse: "daily_verse",
  dailyPrayer: "daily_prayer",
  programs: "programs",
  workerLogs: "worker_logs",
  syncLogs: "sync_logs",
  downloadLogs: "download_logs",
  featureFlags: "feature_flags",
  youtubeVideos: "youtube_videos",
  config: "config",
  notifications: "notifications",
  users: "users",
  aiConversations: "ai_conversations",
} as const;

export const DOCS = {
  youtubeLiveStatus: "youtube_live_status",
};

// AppConfig.verseFallbackReferences, copied verbatim so the scheduled
// function and the client's offline fallback never disagree.
export const VERSE_FALLBACK_REFERENCES = [
  "John 3:16",
  "Psalms 23:1",
  "Philippians 4:13",
  "Romans 8:28",
  "Proverbs 3:5-6",
  "Isaiah 41:10",
  "Jeremiah 29:11",
  "Psalms 46:1",
  "Matthew 11:28",
  "2 Corinthians 5:17",
];

/** Returns today's date key in the app's `yyyy-MM-dd` format, UTC-based. */
export function todayKey(date: Date = new Date()): string {
  const y = date.getUTCFullYear().toString().padStart(4, "0");
  const m = (date.getUTCMonth() + 1).toString().padStart(2, "0");
  const d = date.getUTCDate().toString().padStart(2, "0");
  return `${y}-${m}-${d}`;
}
