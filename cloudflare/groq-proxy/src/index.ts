/**
 * Groq proxy running on Cloudflare Workers instead of a Firebase Cloud
 * Function — see cloudflare/groq-proxy/README.md for the reasoning
 * (Firebase Cloud Functions require the Blaze plan, which needs a
 * payment method on file even to stay within free-tier usage; Cloudflare
 * Workers' free tier needs no card at all and comfortably covers this
 * app's traffic).
 *
 * This Worker does NOT use Firebase's own callable-function auth
 * shortcut (there's no `request.auth` for free here) — it verifies the
 * caller's Firebase ID token itself, against Google's public JWKS for
 * Firebase, using the same `iss`/`aud`/signature checks Firebase's own
 * Admin SDK would do server-side. A request without a valid, current
 * Firebase ID token for THIS project is rejected before ever touching
 * the Groq API key.
 *
 * Endpoints (both POST unless noted):
 *   POST /groqChat   { messages: [...], model?: string } -> { reply: string }
 *   GET  /groqModels                                     -> { modelIds: string[] }
 */

import { createRemoteJWKSet, jwtVerify } from 'jose';

export interface Env {
  GROQ_API_KEY: string;
  FIREBASE_PROJECT_ID: string;
}

const FIREBASE_JWKS_URL =
  'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com';

// Cached across requests within the same Worker isolate — createRemoteJWKSet
// handles its own re-fetch/caching of Google's public keys internally.
const jwks = createRemoteJWKSet(new URL(FIREBASE_JWKS_URL));

function corsHeaders(): HeadersInit {
  return {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  };
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(), 'Content-Type': 'application/json' },
  });
}

/**
 * Verifies a Firebase ID token the same way Firebase's Admin SDK does:
 * RS256 signature against Google's public keys, `iss` matching
 * `https://securetoken.google.com/{projectId}`, `aud` matching the
 * project ID, and standard exp/iat checks (handled by `jose`). Returns
 * the Firebase uid (`sub` claim) on success.
 */
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

async function requireAuth(request: Request, env: Env): Promise<{ uid: string } | Response> {
  const authHeader = request.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    return jsonResponse({ error: 'Missing Authorization: Bearer <Firebase ID token> header.' }, 401);
  }
  const idToken = authHeader.slice('Bearer '.length).trim();
  try {
    const uid = await verifyFirebaseIdToken(idToken, env.FIREBASE_PROJECT_ID);
    return { uid };
  } catch (err) {
    return jsonResponse({ error: `Invalid or expired ID token: ${(err as Error).message}` }, 401);
  }
}

async function handleGroqModels(env: Env): Promise<Response> {
  const resp = await fetch('https://api.groq.com/openai/v1/models', {
    headers: { Authorization: `Bearer ${env.GROQ_API_KEY}` },
  });
  if (!resp.ok) {
    return jsonResponse({ error: `Groq models request failed (${resp.status}).` }, 502);
  }
  const data = (await resp.json()) as { data?: Array<{ id: string }> };
  const modelIds = (data.data ?? []).map((m) => m.id);
  return jsonResponse({ modelIds });
}

async function handleGroqChat(request: Request, env: Env): Promise<Response> {
  let body: { messages?: unknown; model?: unknown };
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: 'Malformed JSON request body.' }, 400);
  }

  if (!Array.isArray(body.messages) || body.messages.length === 0) {
    return jsonResponse({ error: '"messages" must be a non-empty array.' }, 400);
  }
  for (const m of body.messages) {
    if (
      typeof m !== 'object' ||
      m === null ||
      typeof (m as Record<string, unknown>).role !== 'string' ||
      typeof (m as Record<string, unknown>).content !== 'string'
    ) {
      return jsonResponse({ error: 'Every message must have string "role" and "content" fields.' }, 400);
    }
  }

  const model = typeof body.model === 'string' && body.model.length > 0 ? body.model : 'llama-3.3-70b-versatile';

  const groqResp = await fetch('https://api.groq.com/openai/v1/chat/completions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.GROQ_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ model, messages: body.messages }),
  });

  if (!groqResp.ok) {
    const text = await groqResp.text();
    return jsonResponse({ error: `Groq request failed (${groqResp.status}): ${text}` }, 502);
  }

  const data = (await groqResp.json()) as {
    choices?: Array<{ message?: { content?: string } }>;
  };
  const reply = data.choices?.[0]?.message?.content;
  if (typeof reply !== 'string') {
    return jsonResponse({ error: 'Unexpected response shape from Groq.' }, 502);
  }

  return jsonResponse({ reply });
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === 'OPTIONS') {
      return new Response(null, { headers: corsHeaders() });
    }

    const url = new URL(request.url);

    const auth = await requireAuth(request, env);
    if (auth instanceof Response) return auth;

    if (url.pathname === '/groqChat' && request.method === 'POST') {
      return handleGroqChat(request, env);
    }
    if (url.pathname === '/groqModels' && request.method === 'GET') {
      return handleGroqModels(env);
    }

    return jsonResponse({ error: `Not found: ${request.method} ${url.pathname}` }, 404);
  },
};
