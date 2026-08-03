/**
 * Cloudflare Worker replacement for the three remaining Cloud Functions
 * flagged in PHASE2_NOTES.md's honesty note as still requiring Blaze:
 * `dailyVerseSchedule`, `dailyPrayerSchedule`, `cleanupSchedule`. Plus,
 * inline rather than as separate functions, what used to be
 * `onDailyVerseCreated`/`onDailyPrayerCreated` (Firestore triggers — see
 * dailyVerse.ts/dailyPrayer.ts for why folding them in here is a real
 * simplification, not just a workaround for Workers not having Firestore
 * triggers).
 *
 * One Worker, three Cron Triggers (Workers Free plan allows up to 3 per
 * Worker — verified current as of this pass, see README.md) dispatched
 * by `event.cron` in `scheduled()`:
 *
 *   05 23 * * *  (00:05 Africa/Lagos, WAT = UTC+1 year-round, no DST) — daily verse
 *   10 23 * * *  (00:10 Africa/Lagos) — daily prayer, 5 min after verse
 *   35 23 * * *  (00:35 Africa/Lagos) — cleanup, well after both
 *
 * `fetch()` also exposes manual-trigger endpoints (mirroring
 * `generateTodaysVerseNow`/`syncYoutubeNow`'s callable-escape-hatch
 * pattern) for testing without waiting on the schedule, auth'd the same
 * way as the other two Workers (Firebase ID token verified against
 * Google's public JWKS).
 */

import { createRemoteJWKSet, jwtVerify } from 'jose';
import { FirestoreClient, type ServiceAccountKey } from './firestoreClient';
import { ensureTodaysVerse } from './dailyVerse';
import { ensureTodaysPrayer } from './dailyPrayer';
import { runCleanup } from './cleanup';

export interface Env {
  FIREBASE_PROJECT_ID: string;
  GOOGLE_SERVICE_ACCOUNT_JSON: string;
  GROQ_API_KEY: string;
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

async function verifyFirebaseIdToken(idToken: string, projectId: string): Promise<void> {
  await jwtVerify(idToken, jwks, {
    issuer: `https://securetoken.google.com/${projectId}`,
    audience: projectId,
  });
}

function serviceAccountFor(env: Env): ServiceAccountKey {
  return JSON.parse(env.GOOGLE_SERVICE_ACCOUNT_JSON) as ServiceAccountKey;
}

function firestoreFor(env: Env): FirestoreClient {
  return new FirestoreClient(serviceAccountFor(env));
}

async function runVerse(env: Env) {
  return ensureTodaysVerse(serviceAccountFor(env), firestoreFor(env));
}
async function runPrayer(env: Env) {
  return ensureTodaysPrayer(serviceAccountFor(env), firestoreFor(env), env.GROQ_API_KEY);
}
async function runCleanupJob(env: Env) {
  return runCleanup(firestoreFor(env));
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders() });
    }

    const url = new URL(request.url);
    const routes: Record<string, (env: Env) => Promise<unknown>> = {
      '/verseNow': runVerse,
      '/prayerNow': runPrayer,
      '/cleanupNow': runCleanupJob,
    };
    const handler = routes[url.pathname];
    if (!handler || request.method !== 'POST') {
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
      const result = await handler(env);
      return jsonResponse(result);
    } catch (err) {
      return jsonResponse({ error: `${url.pathname} failed: ${(err as Error).message}` }, 502);
    }
  },

  async scheduled(event: ScheduledEvent, env: Env, ctx: ExecutionContext): Promise<void> {
    const job: Record<string, (env: Env) => Promise<unknown>> = {
      '5 23 * * *': runVerse,
      '10 23 * * *': runPrayer,
      '35 23 * * *': runCleanupJob,
    };
    const handler = job[event.cron];
    if (!handler) {
      console.error(`No handler wired for cron expression "${event.cron}" — check wrangler.toml matches index.ts`);
      return;
    }

    ctx.waitUntil(
      (async () => {
        try {
          const result = await handler(env);
          console.log(`Cron "${event.cron}" complete`, result);
        } catch (err) {
          console.error(`Cron "${event.cron}" failed`, err);
        }
      })(),
    );
  },
};
