/**
 * Sends push notifications via FCM's HTTP v1 API, using the same Google
 * Service Account already used for Firestore writes — just with a
 * different OAuth2 scope
 * (`https://www.googleapis.com/auth/firebase.messaging`). The service
 * account's IAM role needs "Firebase Cloud Messaging API Admin" added
 * for this to work (see README.md) — "Cloud Datastore User" alone
 * (sufficient for Firestore writes) does not include messaging.
 *
 * This replaces `onLiveStatusChanged`, a Firestore-triggered Cloud
 * Function — which only exists in the Cloud Functions runtime, not on
 * Workers. Instead of reacting to a Firestore write after the fact, this
 * Worker sends the notification itself, in the same invocation that
 * writes `config/youtube_live_status` — see `index.ts`'s
 * `notifyLiveTransition`.
 *
 * v1 API sends one message per request — there's no server-side
 * multicast the way the legacy API or `sendEachForMulticast` (Admin SDK)
 * had; that "multicast" convenience is actually just the SDK looping the
 * same number of HTTP calls under the hood. Looped here explicitly for
 * the same reason. On the Workers Free plan this is capped by the
 * **50-subrequest-per-invocation limit** — fine for this app's current
 * user count, but the real ceiling to know about if the user base grows:
 * past ~40-45 recipients (leaving headroom for the Firestore reads/writes
 * in the same invocation), either move to the Workers Paid plan (10,000
 * subrequests) or switch to an FCM topic (trade: no more per-user
 * `notifications` Firestore doc, since a topic send doesn't report who
 * received it — see the same tradeoff noted in the original
 * `functions/src/notifications.ts`).
 */

import { FirestoreClient, type ServiceAccountKey } from './firestoreClient';

const MESSAGING_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';

let cachedFcmToken: { token: string; expiresAt: number } | null = null;

async function getFcmAccessToken(serviceAccount: ServiceAccountKey): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedFcmToken && cachedFcmToken.expiresAt > now + 60) {
    return cachedFcmToken.token;
  }

  const header = { alg: 'RS256', typ: 'JWT' };
  const claims = {
    iss: serviceAccount.client_email,
    scope: MESSAGING_SCOPE,
    aud: 'https://oauth2.googleapis.com/token',
    exp: now + 3600,
    iat: now,
  };

  const enc = (input: ArrayBuffer | string) => {
    const bytes = typeof input === 'string' ? new TextEncoder().encode(input) : new Uint8Array(input);
    let binary = '';
    for (const b of bytes) binary += String.fromCharCode(b);
    return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  };
  const unsigned = `${enc(JSON.stringify(header))}.${enc(JSON.stringify(claims))}`;

  const pem = serviceAccount.private_key
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s+/g, '');
  const binary = atob(pem);
  const keyBytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) keyBytes[i] = binary.charCodeAt(i);

  const key = await crypto.subtle.importKey(
    'pkcs8',
    keyBytes.buffer,
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned));
  const jwt = `${unsigned}.${enc(signature)}`;

  const resp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });
  if (!resp.ok) {
    throw new Error(`Failed to get an FCM access token: ${resp.status} ${await resp.text()}`);
  }
  const data = (await resp.json()) as { access_token: string; expires_in: number };
  cachedFcmToken = { token: data.access_token, expiresAt: now + data.expires_in };
  return data.access_token;
}

export interface PushNotification {
  title: string;
  body: string;
  type: string;
  data?: Record<string, string>;
}

/** Sends a single push to one device token via FCM's messages:send endpoint. */
async function sendToToken(
  serviceAccount: ServiceAccountKey,
  token: string,
  notification: PushNotification,
): Promise<boolean> {
  const accessToken = await getFcmAccessToken(serviceAccount);
  const resp = await fetch(
    `https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        message: {
          token,
          notification: { title: notification.title, body: notification.body },
          data: { type: notification.type, ...(notification.data ?? {}) },
        },
      }),
    },
  );
  return resp.ok;
}

/**
 * Loads every user with a saved `fcm_token` via a Firestore structured
 * query (REST equivalent of `.where('fcm_token', '!=', null)`), sends
 * one push per token, and writes a matching `notifications` doc per
 * successfully-notified user — same behavior as
 * `functions/src/notifications.ts`'s `fanOutNotification`, just without
 * `firebase-admin`. See this file's header comment for the free-plan
 * subrequest ceiling this loop runs into at scale.
 */
export async function fanOutNotification(
  serviceAccount: ServiceAccountKey,
  firestore: FirestoreClient,
  notification: PushNotification,
): Promise<{ sent: number; failed: number }> {
  const users = await firestore.queryUsersWithFcmToken();
  let sent = 0;
  let failed = 0;

  for (const user of users) {
    const ok = await sendToToken(serviceAccount, user.token, notification);
    if (ok) {
      sent++;
      await firestore.createDoc('notifications', {
        uid: user.uid,
        title: notification.title,
        body: notification.body,
        data: { type: notification.type, ...(notification.data ?? {}) },
        read: false,
        created_at: new Date().toISOString(),
      });
    } else {
      failed++;
    }
  }

  return { sent, failed };
}
