/**
 * Cloudflare Worker replacement for functions/src/youtubeSync.ts — the
 * second (and last) piece of avoiding Firebase Blaze entirely, after the
 * Groq proxy (cloudflare/groq-proxy/). Two entry points:
 *
 *   - `scheduled()` — Cron Trigger, runs every 15 minutes, same cadence
 *     as `youtubeSyncSchedule`.
 *   - `fetch()` — POST /syncNow, same job as the `syncYoutubeNow`
 *     callable, auth'd the same way as the Groq proxy (Firebase ID token
 *     verified against Google's public JWKS).
 *
 * Both write to Firestore via a real Google Service Account (see
 * firestoreClient.ts) so `firestore.rules`' `allow write: if false` on
 * `youtube_videos`/`config` (server-only, by design — see that file)
 * stays intact. This is NOT relaxed to let the client write directly;
 * that would be a real security regression just to make this migration
 * easier.
 */

import { createRemoteJWKSet, jwtVerify } from 'jose';
import { FirestoreClient, type ServiceAccountKey } from './firestoreClient';
import { syncYoutube } from './youtube';

export interface Env {
  YOUTUBE_API_KEY: string;
  FIREBASE_PROJECT_ID: string;
  // The full service account JSON key, as a string secret — see
  // README.md for how to create one and what IAM role it needs
  // (Cloud Datastore User is enough; doesn't need project-wide Editor).
  GOOGLE_SERVICE_ACCOUNT_JSON: string;
}

const FIREBASE_JWKS_URL =
  'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';
const jwks = createRemoteJWKSet(new URL(FIREBASE_JWKS_URL));

function corsHeaders(): HeadersInit {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
  };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(), 'Content-Type': 'application/json' },
  });
}

async function verifyFirebaseIdToken(idToken: string, projectId: string): Promise<string> {
  const { payload } = await jwtVerify(idToken, jwks, {
    issuer: `https://securetoken.google.com/${projectId}`,
    audience: projectId,
  });
  if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
    throw new Error('Token missing a valid subject (uid) claim.');
  }
  return payload.sub;
}

function firestoreClientFor(env: Env): FirestoreClient {
  const serviceAccount = JSON.parse(env.GOOGLE_SERVICE_ACCOUNT_JSON) as ServiceAccountKey;
  return new FirestoreClient(serviceAccount);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders() });
    }

    const url = new URL(request.url);
    if (url.pathname !== '/syncNow' || request.method !== 'POST') {
      return jsonResponse({ error: `Not found: ${request.method} ${url.pathname}` }, 404);
    }

    const authHeader = request.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      return jsonResponse({ error: 'Missing Authorization: Bearer <Firebase ID token> header.' }, 401);
    }
    try {
      await verifyFirebaseIdToken(authHeader.slice('Bearer '.length).trim(), env.FIREBASE_PROJECT_ID);
    } catch (err) {
      return jsonResponse({ error: `Invalid or expired ID token: ${(err as Error).message}` }, 401);
    }

    try {
      const result = await syncYoutube(env.YOUTUBE_API_KEY, firestoreClientFor(env));
      return jsonResponse(result);
    } catch (err) {
      return jsonResponse({ error: `Sync failed: ${(err as Error).message}` }, 502);
    }
  },

  async scheduled(_event: ScheduledEvent, env: Env, ctx: ExecutionContext): Promise<void> {
    ctx.waitUntil(
      (async () => {
        try {
          const result = await syncYoutube(env.YOUTUBE_API_KEY, firestoreClientFor(env));
          console.log('YouTube sync complete', result);
        } catch (err) {
          console.error('YouTube sync failed', err);
        }
      })(),
    );
  },
};
