/**
 * Collection names + fallback references mirrored from
 * lib/core/config/app_config.dart and functions/src/config.ts. Same
 * hand-synced-constants tradeoff already accepted across this repo (see
 * functions/src/config.ts's header comment) — no cross-language codegen.
 * If you rename a collection in app_config.dart, update this file too.
 */

export const COLLECTIONS = {
  dailyVerse: 'daily_verse',
  dailyPrayer: 'daily_prayer',
  workerLogs: 'worker_logs',
  syncLogs: 'sync_logs',
  downloadLogs: 'download_logs',
  notifications: 'notifications',
} as const;

// AppConfig.verseFallbackReferences, copied verbatim so this Worker and
// the client's offline fallback (VerseWorker) never disagree on which
// reference a given day-of-month maps to.
export const VERSE_FALLBACK_REFERENCES = [
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

/** Picks today's reference the same deterministic way VerseWorker's client-side fallback does. */
export function referenceForDate(date: Date): string {
  return VERSE_FALLBACK_REFERENCES[date.getUTCDate() % VERSE_FALLBACK_REFERENCES.length];
}

/** Today's date key in the app's `yyyy-MM-dd` format, UTC-based. */
export function todayKey(date: Date = new Date()): string {
  const y = date.getUTCFullYear().toString().padStart(4, '0');
  const m = (date.getUTCMonth() + 1).toString().padStart(2, '0');
  const d = date.getUTCDate().toString().padStart(2, '0');
  return `${y}-${m}-${d}`;
}
