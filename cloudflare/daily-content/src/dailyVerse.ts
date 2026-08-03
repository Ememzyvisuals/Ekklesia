/**
 * Ported from functions/src/dailyVerse.ts. Same logic — the only real
 * change (beyond REST vs. Admin SDK) is that the push-notification
 * fan-out that used to be a separate Cloud Function (`onDailyVerseCreated`,
 * triggered by this doc's creation) now happens inline, right after the
 * write, in the same function call. See this Worker's README.md for why
 * that's a simplification rather than a workaround: a Firestore trigger
 * exists specifically to notify something *else* about a write it didn't
 * cause itself; here, the thing making the write and the thing sending
 * the notification are already the same code path, so there was never a
 * good reason for two hops through Firestore's event system in the first
 * place — only that Cloud Functions' scheduler and Firestore triggers
 * happen to be two different features once you're on that platform.
 */

import type { ServiceAccountKey } from './firestoreClient';
import { FirestoreClient } from './firestoreClient';
import { COLLECTIONS, referenceForDate, todayKey } from './config';
import { fetchEnglishVerseText } from './bibleText';
import { fanOutNotification } from './fcm';

export async function ensureTodaysVerse(
  serviceAccount: ServiceAccountKey,
  firestore: FirestoreClient,
): Promise<{ created: boolean; reference: string }> {
  const key = todayKey();
  const path = `${COLLECTIONS.dailyVerse}/${key}`;

  const existing = await firestore.get(path);
  if (existing) {
    return { created: false, reference: (existing.reference as string) ?? '' };
  }

  const reference = referenceForDate(new Date());
  const text = await fetchEnglishVerseText(reference);

  await firestore.set(path, {
    reference,
    ...(text ? { text_en: text } : {}),
    generated_at: new Date().toISOString(),
    source: 'cloudflare_worker',
  });

  try {
    const result = await fanOutNotification(serviceAccount, firestore, {
      title: "Today's Verse",
      body: reference,
      type: 'todays_verse',
    });
    console.log('Daily verse push sent', result);
  } catch (err) {
    // Never let a notification failure make the whole run look failed —
    // the verse doc itself already wrote successfully, which is the
    // part every client's Home screen actually depends on.
    console.error('Daily verse push failed', err);
  }

  return { created: true, reference };
}
