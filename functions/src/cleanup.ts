import { onSchedule } from "firebase-functions/v2/scheduler";
import * as logger from "firebase-functions/logger";
import { getFirestore, Timestamp } from "firebase-admin/firestore";
import { COLLECTIONS } from "./config";

// Same retention windows as CleanupWorker.instance — _maxNotificationAge /
// _maxLogAge in cleanup_worker.dart. Kept identical so client and server
// pruning agree on what "old" means; only the scope differs (this runs
// across every user's notifications, not just whichever uid is signed in
// on a given device when CleanupWorker.runOnce fires).
const MAX_NOTIFICATION_AGE_DAYS = 30;
const MAX_LOG_AGE_DAYS = 14;

async function pruneCollection(collection: string, maxAgeDays: number): Promise<number> {
  const db = getFirestore();
  const cutoff = Timestamp.fromMillis(Date.now() - maxAgeDays * 24 * 60 * 60 * 1000);

  let totalDeleted = 0;
  // Loop in capped pages rather than one unbounded query — same reasoning
  // as CleanupWorker's own 200-doc-per-pass cap, just repeated in-process
  // here since a scheduled function has more time budget per run than a
  // foreground client call does.
  while (true) {
    const snapshot = await db.collection(collection).where("created_at", "<", cutoff).limit(300).get();
    if (snapshot.empty) break;

    const batch = db.batch();
    snapshot.docs.forEach((doc) => batch.delete(doc.ref));
    await batch.commit();
    totalDeleted += snapshot.size;

    if (snapshot.size < 300) break;
  }
  return totalDeleted;
}

export const cleanupSchedule = onSchedule(
  { schedule: "every 24 hours", region: "us-central1" },
  async () => {
    const results = await Promise.allSettled([
      pruneCollection(COLLECTIONS.notifications, MAX_NOTIFICATION_AGE_DAYS),
      pruneCollection(COLLECTIONS.workerLogs, MAX_LOG_AGE_DAYS),
      pruneCollection(COLLECTIONS.syncLogs, MAX_LOG_AGE_DAYS),
      pruneCollection(COLLECTIONS.downloadLogs, MAX_LOG_AGE_DAYS),
    ]);

    results.forEach((result, index) => {
      const label = [COLLECTIONS.notifications, COLLECTIONS.workerLogs, COLLECTIONS.syncLogs, COLLECTIONS.downloadLogs][index];
      if (result.status === "fulfilled") {
        logger.info(`Pruned ${label}`, { deleted: result.value });
      } else {
        logger.error(`Prune failed for ${label}`, { error: `${result.reason}` });
      }
    });
  }
);
