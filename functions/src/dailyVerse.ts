import { onSchedule } from "firebase-functions/v2/scheduler";
import { onCall, HttpsError } from "firebase-functions/v2/https";
import * as logger from "firebase-functions/logger";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { COLLECTIONS, VERSE_FALLBACK_REFERENCES, todayKey } from "./config";
import { fetchEnglishVerseText } from "./bibleText";

/**
 * Picks today's reference the same way VerseWorker's offline fallback
 * does client-side (`day-of-month % list.length`) — kept identical so a
 * client that generates before this function ever runs (e.g. this
 * function is disabled, or Cloud Scheduler hasn't fired yet for a new
 * deploy) picks the *same* reference, not a conflicting one.
 */
function referenceForDate(date: Date): string {
  return VERSE_FALLBACK_REFERENCES[date.getUTCDate() % VERSE_FALLBACK_REFERENCES.length];
}

async function ensureTodaysVerse(): Promise<void> {
  const db = getFirestore();
  const key = todayKey();
  const ref = db.collection(COLLECTIONS.dailyVerse).doc(key);

  const existing = await ref.get();
  if (existing.exists) {
    logger.info(`daily_verse/${key} already exists — skipping`, { key });
    return;
  }

  const reference = referenceForDate(new Date());
  const text = await fetchEnglishVerseText(reference);

  await ref.set({
    reference,
    ...(text ? { text_en: text } : {}),
    generated_at: FieldValue.serverTimestamp(),
    source: "cloud_function_v1",
  });

  logger.info(`Wrote daily_verse/${key}`, { reference, hasText: !!text });
}

// Runs once daily at 00:05 Africa/Lagos (WAT, UTC+1 year-round — no DST),
// ahead of typical morning opens so the first client of the day reads
// instead of generates. VerseWorker's client-side generation path stays
// as a safety net (see its doc comment) for the rare case this function
// is ever disabled or Cloud Scheduler misses a run.
export const dailyVerseSchedule = onSchedule(
  { schedule: "5 0 * * *", timeZone: "Africa/Lagos", region: "us-central1" },
  async () => {
    await ensureTodaysVerse();
  }
);

// Callable escape hatch for manual testing / immediate backfill without
// waiting for the schedule (`firebase functions:shell` or a one-off call
// from an admin tool) — not exposed in the Flutter app.
export const generateTodaysVerseNow = onCall({ region: "us-central1" }, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Sign-in required.");
  }
  await ensureTodaysVerse();
  return { ok: true };
});
