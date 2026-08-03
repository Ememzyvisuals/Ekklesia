/**
 * Same FCM HTTP v1 API client as cloudflare/youtube-sync/src/fcm.ts —
 * see that file's header comment for the full reasoning (service account
 * OAuth2 scope, per-token send loop, Free-plan 50-subrequest ceiling).
 * Duplicated rather than shared as an npm package across the two Workers
 * — each Worker here is deployed independently and self-contained, same
 * convention youtube-sync already established for firestoreClient.ts.
 */

import type { FirestoreClient } from './firestoreClient';
import type { ServiceAccountKey } from './firestoreClient';

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
 * Loads every user with a saved `fcm_token`, sends one push per token,
 * and writes a matching `notifications` doc per successfully-notified
 * user — replaces `functions/src/notifications.ts`'s `onDailyVerseCreated`
 * / `onDailyPrayerCreated` (Firestore triggers). Called directly from
 * `dailyVerse.ts`/`dailyPrayer.ts` right after the write, instead of a
 * separate function reacting to it — see this Worker's README.md for why
 * that's actually a simplification, not just a workaround.
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
