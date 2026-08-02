/**
 * Lets a Cloudflare Worker write to Firestore with admin-level access —
 * the same thing `firebase-admin` gives Cloud Functions for free, but a
 * Worker has no Node runtime and can't use that SDK. This is the
 * highest-risk, least-conventional piece of this migration: hand-rolling
 * a Google Service Account's OAuth2 JWT-Bearer flow using only the Web
 * Crypto API, then calling Firestore's plain REST API instead of a
 * typed SDK. The pattern itself is standard and documented (Google's own
 * docs describe exactly this flow for non-Node environments) — what's
 * unverified is this specific implementation, since there's no way to
 * run it against a real service account from this sandbox. Test this
 * file first and carefully before trusting the sync jobs that depend on
 * it — see cloudflare/youtube-sync/README.md.
 */

export interface ServiceAccountKey {
  client_email: string;
  private_key: string;
  project_id: string;
}

function base64UrlEncode(input: ArrayBuffer | string): string {
  const bytes = typeof input === 'string' ? new TextEncoder().encode(input) : new Uint8Array(input);
  let binary = '';
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const b64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s+/g, '');
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

let cachedToken: { token: string; expiresAt: number } | null = null;

async function getAccessToken(serviceAccount: ServiceAccountKey): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  // Reused across invocations within the same Worker isolate — avoids
  // signing a new JWT and round-tripping to Google on every single call
  // when several sync operations happen close together.
  if (cachedToken && cachedToken.expiresAt > now + 60) {
    return cachedToken.token;
  }

  const header = { alg: 'RS256', typ: 'JWT' };
  const claims = {
    iss: serviceAccount.client_email,
    scope: 'https://www.googleapis.com/auth/datastore',
    aud: 'https://oauth2.googleapis.com/token',
    exp: now + 3600,
    iat: now,
  };

  const unsigned = `${base64UrlEncode(JSON.stringify(header))}.${base64UrlEncode(JSON.stringify(claims))}`;

  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToArrayBuffer(serviceAccount.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );

  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(unsigned));
  const jwt = `${unsigned}.${base64UrlEncode(signature)}`;

  const resp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: jwt,
    }),
  });

  if (!resp.ok) {
    throw new Error(`Failed to get a Google access token: ${resp.status} ${await resp.text()}`);
  }

  const data = (await resp.json()) as { access_token: string; expires_in: number };
  cachedToken = { token: data.access_token, expiresAt: now + data.expires_in };
  return data.access_token;
}

/** Converts a plain JS value into Firestore REST API's typed "Value" wire format. */
function toFirestoreValue(value: unknown): Record<string, unknown> {
  if (value === null || value === undefined) return { nullValue: null };
  if (typeof value === 'string') return { stringValue: value };
  if (typeof value === 'boolean') return { booleanValue: value };
  if (typeof value === 'number') {
    return Number.isInteger(value) ? { integerValue: String(value) } : { doubleValue: value };
  }
  if (Array.isArray(value)) {
    return { arrayValue: { values: value.map(toFirestoreValue) } };
  }
  if (typeof value === 'object') {
    return { mapValue: { fields: toFirestoreFields(value as Record<string, unknown>) } };
  }
  throw new Error(`Cannot convert value to Firestore format: ${JSON.stringify(value)}`);
}

function toFirestoreFields(obj: Record<string, unknown>): Record<string, unknown> {
  const fields: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) fields[k] = toFirestoreValue(v);
  return fields;
}

export class FirestoreClient {
  constructor(private serviceAccount: ServiceAccountKey) {}

  private get baseUrl(): string {
    return `https://firestore.googleapis.com/v1/projects/${this.serviceAccount.project_id}/databases/(default)/documents`;
  }

  /**
   * Merge-sets fields on a document — matches `firebase-admin`'s
   * `.set(data, {merge: true})`, which is what `youtubeSync.ts`'s Cloud
   * Function version uses. Implemented via PATCH + `updateMask` listing
   * every top-level field being written, which is Firestore REST's
   * documented way to achieve merge semantics (only touches the listed
   * fields; leaves any others on the document alone).
   */
  async mergeSet(path: string, data: Record<string, unknown>): Promise<void> {
    const token = await getAccessToken(this.serviceAccount);
    const mask = Object.keys(data)
      .map((k) => `updateMask.fieldPaths=${encodeURIComponent(k)}`)
      .join('&');
    const url = `${this.baseUrl}/${path}?${mask}`;

    const resp = await fetch(url, {
      method: 'PATCH',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ fields: toFirestoreFields(data) }),
    });

    if (!resp.ok) {
      throw new Error(`Firestore write failed for "${path}": ${resp.status} ${await resp.text()}`);
    }
  }
}
