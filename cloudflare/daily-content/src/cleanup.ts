/**
 * Ported from functions/src/cleanup.ts. Same retention windows as
 * CleanupWorker.instance (`_maxNotificationAge`/`_maxLogAge` in
 * cleanup_worker.dart) and the same page-in-capped-batches loop — see
 * that file's comments for why. Prunes across ALL users, unlike the
 * client's CleanupWorker, which only ever prunes whoever's signed in on
 * that device.
 */

import { FirestoreClient } from './firestoreClient';
import { COLLECTIONS } from './config';

const MAX_NOTIFICATION_AGE_DAYS = 30;
const MAX_LOG_AGE_DAYS = 14;
const PAGE_SIZE = 300;

async function pruneCollection(firestore: FirestoreClient, collection: string, maxAgeDays: number): Promise<number> {
  const cutoff = new Date(Date.now() - maxAgeDays * 24 * 60 * 60 * 1000);
  let totalDeleted = 0;

  while (true) {
    const docNames = await firestore.queryOlderThan(collection, cutoff, PAGE_SIZE);
    if (docNames.length === 0) break;

    await firestore.batchDelete(docNames);
    totalDeleted += docNames.length;

    if (docNames.length < PAGE_SIZE) break;
  }
  return totalDeleted;
}

export async function runCleanup(firestore: FirestoreClient): Promise<Record<string, number | string>> {
  const targets: Array<[string, number]> = [
    [COLLECTIONS.notifications, MAX_NOTIFICATION_AGE_DAYS],
    [COLLECTIONS.workerLogs, MAX_LOG_AGE_DAYS],
    [COLLECTIONS.syncLogs, MAX_LOG_AGE_DAYS],
    [COLLECTIONS.downloadLogs, MAX_LOG_AGE_DAYS],
  ];

  const results: Record<string, number | string> = {};
  for (const [collection, maxAgeDays] of targets) {
    try {
      results[collection] = await pruneCollection(firestore, collection, maxAgeDays);
    } catch (err) {
      results[collection] = `failed: ${(err as Error).message}`;
    }
  }
  return results;
}
