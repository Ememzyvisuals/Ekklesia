/**
 * Ported from functions/src/dailyPrayer.ts — same inline-fan-out change
 * as dailyVerse.ts (replaces `onDailyPrayerCreated`). See that file's
 * header comment for the reasoning.
 */

import type { ServiceAccountKey } from './firestoreClient';
import { FirestoreClient } from './firestoreClient';
import { COLLECTIONS, referenceForDate, todayKey } from './config';
import { callGroq } from './groq';
import { fanOutNotification } from './fcm';

const FALLBACK_PRAYER_TEXT =
  'Lord, thank You for this day. Guide my steps, renew my strength, and help ' +
  'me walk in Your word. Amen.';

const SYSTEM_PROMPT =
  'You write short, warm, biblically grounded daily prayers (4-6 sentences) ' +
  'for a Christian devotional app. Base the prayer thematically on the given ' +
  "verse reference without quoting long passages of scripture. Plain text " +
  'only, no markdown, no preamble like "Here is a prayer".';

export async function ensureTodaysPrayer(
  serviceAccount: ServiceAccountKey,
  firestore: FirestoreClient,
  groqApiKey: string,
): Promise<{ created: boolean; reference: string }> {
  const key = todayKey();
  const prayerPath = `${COLLECTIONS.dailyPrayer}/${key}`;

  const existing = await firestore.get(prayerPath);
  if (existing) {
    return { created: false, reference: (existing.based_on_reference as string) ?? '' };
  }

  const verseDoc = await firestore.get(`${COLLECTIONS.dailyVerse}/${key}`);
  const reference = (verseDoc?.reference as string | undefined) ?? referenceForDate(new Date());

  let text: string;
  try {
    text = await callGroq(
      [
        { role: 'system', content: SYSTEM_PROMPT },
        { role: 'user', content: `Write today's prayer based on ${reference}.` },
      ],
      groqApiKey,
    );
  } catch (err) {
    console.warn('Groq call failed for daily prayer — using static fallback text', err);
    text = FALLBACK_PRAYER_TEXT;
  }

  await firestore.set(prayerPath, {
    text,
    based_on_reference: reference,
    generated_at: new Date().toISOString(),
    source: 'cloudflare_worker',
  });

  try {
    const preview = text.length > 100 ? `${text.slice(0, 97)}...` : text;
    const result = await fanOutNotification(serviceAccount, firestore, {
      title: "Today's Prayer is ready",
      body: preview,
      type: 'todays_prayer',
    });
    console.log('Daily prayer push sent', result);
  } catch (err) {
    console.error('Daily prayer push failed', err);
  }

  return { created: true, reference };
}
