import { onDocumentCreated, onDocumentWritten } from "firebase-functions/v2/firestore";
import * as logger from "firebase-functions/logger";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { COLLECTIONS, DOCS } from "./config";

interface TokenUser {
  uid: string;
  token: string;
}

/**
 * Loads every user with a saved fcm_token. NotificationService.
 * _saveTokenToUser (client-side) is what populates this — see
 * main.dart's auth-state listener, which was the missing call that made
 * this whole path dead until this pass wired it in.
 *
 * Scope note: this loads the whole `users` collection into memory for a
 * fan-out send. Fine at this app's current scale; if the user base grows
 * into the tens of thousands this should move to FCM topics (subscribe
 * each client to a `daily_content` topic instead) rather than a
 * collection scan + per-user send. Not built that way preemptively
 * because topics have their own tradeoffs (harder to fan out
 * per-user `notifications` Firestore docs, since a topic send doesn't
 * tell you who received it).
 */
async function loadUsersWithTokens(): Promise<TokenUser[]> {
  const db = getFirestore();
  const snapshot = await db.collection(COLLECTIONS.users).where("fcm_token", "!=", null).get();
  return snapshot.docs
    .map((doc) => ({ uid: doc.id, token: doc.data().fcm_token as string | undefined }))
    .filter((u): u is TokenUser => !!u.token);
}

/**
 * Sends one push per user in batches of 500 (FCM's multicast limit) and
 * writes a matching `notifications` doc per user so NotificationWorker's
 * history/unread-count still works for anyone who had the app closed
 * when the push went out — mirrors what NotificationService.
 * _recordNotification does for a foreground-received message, just
 * triggered server-side instead of from an onMessage listener.
 */
async function fanOutNotification(params: {
  title: string;
  body: string;
  type: string;
  data?: Record<string, string>;
}): Promise<void> {
  const db = getFirestore();
  const users = await loadUsersWithTokens();
  if (users.length === 0) {
    logger.info("No users with fcm_token yet — skipping fan-out", { type: params.type });
    return;
  }

  const messaging = getMessaging();
  const batchSize = 500;

  for (let i = 0; i < users.length; i += batchSize) {
    const chunk = users.slice(i, i + batchSize);

    const sendResult = await messaging.sendEachForMulticast({
      tokens: chunk.map((u) => u.token),
      notification: { title: params.title, body: params.body },
      data: { type: params.type, ...(params.data ?? {}) },
    });

    const writeBatch = db.batch();
    chunk.forEach((user) => {
      const ref = db.collection(COLLECTIONS.notifications).doc();
      writeBatch.set(ref, {
        uid: user.uid,
        title: params.title,
        body: params.body,
        data: { type: params.type, ...(params.data ?? {}) },
        read: false,
        created_at: FieldValue.serverTimestamp(),
      });
    });
    await writeBatch.commit();

    logger.info("Notification batch sent", {
      type: params.type,
      chunkSize: chunk.length,
      successCount: sendResult.successCount,
      failureCount: sendResult.failureCount,
    });
  }
}

export const onDailyVerseCreated = onDocumentCreated(
  { document: `${COLLECTIONS.dailyVerse}/{date}`, region: "us-central1" },
  async (event) => {
    const reference = event.data?.data()?.reference as string | undefined;
    if (!reference) return;
    await fanOutNotification({
      title: "Today's Verse",
      body: reference,
      type: "todays_verse",
    });
  }
);

export const onDailyPrayerCreated = onDocumentCreated(
  { document: `${COLLECTIONS.dailyPrayer}/{date}`, region: "us-central1" },
  async (event) => {
    const text = event.data?.data()?.text as string | undefined;
    if (!text) return;
    const preview = text.length > 100 ? `${text.slice(0, 97)}...` : text;
    await fanOutNotification({
      title: "Today's Prayer is ready",
      body: preview,
      type: "todays_prayer",
    });
  }
);

/**
 * Only fires on the live -> not-live or not-live -> live transition, not
 * on every metadata refresh youtubeSyncSchedule writes (title tweaks,
 * thumbnail changes) — those would otherwise re-notify every 15 minutes
 * for the same broadcast.
 */
export const onLiveStatusChanged = onDocumentWritten(
  { document: `${COLLECTIONS.config}/${DOCS.youtubeLiveStatus}`, region: "us-central1" },
  async (event) => {
    const before = event.data?.before?.data();
    const after = event.data?.after?.data();

    const wasLive = !!before?.video_id && before?.live_status === "live";
    const isLive = !!after?.video_id && after?.live_status === "live";

    if (!wasLive && isLive) {
      await fanOutNotification({
        title: "DCLM is live now",
        body: (after?.title as string | undefined) ?? "Tap to watch.",
        type: "live_program",
        data: { videoId: after?.video_id as string },
      });
    }
  }
);
