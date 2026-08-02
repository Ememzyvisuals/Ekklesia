import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { COLLECTIONS, VERSE_FALLBACK_REFERENCES, todayKey } from "./config";
import { callGroq, groqApiKeySecret } from "./groq";

const FALLBACK_PRAYER_TEXT =
  "Lord, thank You for this day. Guide my steps, renew my strength, and help " +
  "me walk in Your word. Amen.";

function referenceForDate(date: Date): string {
  return VERSE_FALLBACK_REFERENCES[date.getUTCDate() % VERSE_FALLBACK_REFERENCES.length];
}

const SYSTEM_PROMPT =
  "You write short, warm, biblically grounded daily prayers (4-6 sentences) " +
  "for a Christian devotional app. Base the prayer thematically on the given " +
  'verse reference without quoting long passages of scripture. Plain text ' +
  'only, no markdown, no preamble like "Here is a prayer".';

/**
 * Runs at 00:10 Africa/Lagos — 5 minutes after dailyVerseSchedule, so
 * today's verse doc almost always already exists by the time this reads
 * it. Falls back to the same deterministic reference calculation if it
 * doesn't (e.g. dailyVerseSchedule failed this run), rather than skipping
 * the prayer entirely.
 */
export const dailyPrayerSchedule = onSchedule(
  {
    schedule: "10 0 * * *",
    timeZone: "Africa/Lagos",
    region: "us-central1",
    secrets: [groqApiKeySecret],
  },
  async () => {
    const db = getFirestore();
    const key = todayKey();
    const prayerRef = db.collection(COLLECTIONS.dailyPrayer).doc(key);

    const existing = await prayerRef.get();
    if (existing.exists) {
      logger.info(`daily_prayer/${key} already exists — skipping`, { key });
      return;
    }

    const verseDoc = await db.collection(COLLECTIONS.dailyVerse).doc(key).get();
    const reference = (verseDoc.data()?.reference as string | undefined) ?? referenceForDate(new Date());

    let text: string;
    try {
      text = await callGroq(
        [
          { role: "system", content: SYSTEM_PROMPT },
          { role: "user", content: `Write today's prayer based on ${reference}.` },
        ],
        groqApiKeySecret.value()
      );
    } catch (e) {
      logger.warn("Groq call failed for daily prayer — using static fallback text", { error: `${e}` });
      text = FALLBACK_PRAYER_TEXT;
    }

    await prayerRef.set({
      text,
      based_on_reference: reference,
      generated_at: FieldValue.serverTimestamp(),
      source: "cloud_function_v1",
    });

    logger.info(`Wrote daily_prayer/${key}`, { reference });
  }
);
