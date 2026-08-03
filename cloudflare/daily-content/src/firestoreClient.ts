/**
 * Same hand-rolled Service Account OAuth2 + Firestore REST pattern as
 * cloudflare/youtube-sync/src/firestoreClient.ts (see that file's header
 * comment for the full reasoning and honesty note on this being the
 * least-conventional piece of these migrations). This copy adds
 * `queryOlderThan` + `batchDelete`, needed for `cleanup.ts` but not by
 * the YouTube Worker.
 */

export interface ServiceAccountKey {
  client_email: string;
  private_key: string;
  project_id: string;
}

const DATASTORE_SCOPE = 'https://www.googleapis.com/auth/datastore';

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
  if (cachedToken && cachedToken.expiresAt > now + 60) {
    return cachedToken.token;
  }

  const header = { alg: 'RS256', typ: 'JWT' };
  const claims = {
    iss: serviceAccount.client_email,
    scope: DATASTORE_SCOPE,
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

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function fromFirestoreValue(value: any): unknown {
  if (value == null) return null;
  if ('nullValue' in value) return null;
  if ('stringValue' in value) return value.stringValue;
  if ('booleanValue' in value) return value.booleanValue;
  if ('integerValue' in value) return parseInt(value.integerValue, 10);
  if ('doubleValue' in value) return value.doubleValue;
  if ('timestampValue' in value) return value.timestampValue;
  if ('arrayValue' in value) return (value.arrayValue.values ?? []).map(fromFirestoreValue);
  if ('mapValue' in value) return fromFirestoreFields(value.mapValue.fields ?? {});
  return null;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function fromFirestoreFields(fields: Record<string, any>): Record<string, unknown> {
  const obj: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(fields)) obj[k] = fromFirestoreValue(v);
  return obj;
}

export class FirestoreClient {
  constructor(private serviceAccount: ServiceAccountKey) {}

  private get baseUrl(): string {
    return `https://firestore.googleapis.com/v1/projects/${this.serviceAccount.project_id}/databases/(default)/documents`;
  }

  async get(path: string): Promise<Record<string, unknown> | null> {
    const token = await getAccessToken(this.serviceAccount);
    const resp = await fetch(`${this.baseUrl}/${path}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    if (resp.status === 404) return null;
    if (!resp.ok) {
      throw new Error(`Firestore read failed for "${path}": ${resp.status} ${await resp.text()}`);
    }
    const json = (await resp.json()) as { fields?: Record<string, unknown> };
    return fromFirestoreFields(json.fields ?? {});
  }

  /**
   * Set semantics (not merge) — used only for daily_verse/daily_prayer,
   * which are always brand-new docs for a never-seen-before date key, so
   * merge-vs-set doesn't matter in practice here (unlike YouTube's
   * repeatedly-updated video docs, where merge matters a lot).
   */
  async set(path: string, data: Record<string, unknown>): Promise<void> {
    const token = await getAccessToken(this.serviceAccount);
    const resp = await fetch(`${this.baseUrl}/${path}`, {
      method: 'PATCH',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ fields: toFirestoreFields(data) }),
    });
    if (!resp.ok) {
      throw new Error(`Firestore write failed for "${path}": ${resp.status} ${await resp.text()}`);
    }
  }

  async createDoc(collection: string, data: Record<string, unknown>): Promise<void> {
    const token = await getAccessToken(this.serviceAccount);
    const resp = await fetch(`${this.baseUrl}/${collection}`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ fields: toFirestoreFields(data) }),
    });
    if (!resp.ok) {
      throw new Error(`Firestore create failed in "${collection}": ${resp.status} ${await resp.text()}`);
    }
  }

  async queryUsersWithFcmToken(): Promise<Array<{ uid: string; token: string }>> {
    const token = await getAccessToken(this.serviceAccount);
    const resp = await fetch(`${this.baseUrl}:runQuery`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        structuredQuery: {
          from: [{ collectionId: 'users' }],
          where: {
            fieldFilter: {
              field: { fieldPath: 'fcm_token' },
              op: 'NOT_EQUAL',
              value: { nullValue: null },
            },
          },
        },
      }),
    });
    if (!resp.ok) {
      throw new Error(`Firestore query failed for users with fcm_token: ${resp.status} ${await resp.text()}`);
    }
    const rows = (await resp.json()) as Array<{ document?: { name: string; fields?: Record<string, unknown> } }>;
    return rows
      .filter((row) => row.document)
      .map((row) => {
        const doc = row.document!;
        const uid = doc.name.split('/').pop() ?? '';
        const fields = fromFirestoreFields(doc.fields ?? {});
        return { uid, token: fields.fcm_token as string };
      })
      .filter((u) => !!u.token);
  }

  /**
   * Returns up to `limit` document paths in `collection` whose
   * `created_at` is older than `cutoff` — the REST equivalent of
   * `cleanupSchedule`'s `.where('created_at', '<', cutoff).limit(300)`.
   * `cleanup.ts` pages through this in a loop the same way the Cloud
   * Function did, since REST's `runQuery` has the same per-call result
   * cap concerns as any Firestore query.
   */
  async queryOlderThan(collection: string, cutoff: Date, limit: number): Promise<string[]> {
    const token = await getAccessToken(this.serviceAccount);
    const resp = await fetch(`${this.baseUrl}:runQuery`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        structuredQuery: {
          from: [{ collectionId: collection }],
          where: {
            fieldFilter: {
              field: { fieldPath: 'created_at' },
              op: 'LESS_THAN',
              value: { timestampValue: cutoff.toISOString() },
            },
          },
          limit,
        },
      }),
    });
    if (!resp.ok) {
      throw new Error(`Firestore query failed for "${collection}": ${resp.status} ${await resp.text()}`);
    }
    const rows = (await resp.json()) as Array<{ document?: { name: string } }>;
    return rows.filter((r) => r.document).map((r) => r.document!.name);
  }

  /**
   * Firestore REST has a `:commit` batch-write endpoint (unlike the
   * per-doc-only PATCH/POST used elsewhere in this file) — used here
   * instead of one DELETE call per doc, both for speed and to stay
   * further under the Workers Free plan's 50-subrequest-per-invocation
   * cap when pruning hundreds of stale docs.
   */
  async batchDelete(documentNames: string[]): Promise<void> {
    if (documentNames.length === 0) return;
    const token = await getAccessToken(this.serviceAccount);
    const resp = await fetch(`${this.baseUrl}:commit`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        writes: documentNames.map((name) => ({ delete: name })),
      }),
    });
    if (!resp.ok) {
      throw new Error(`Firestore batch delete failed: ${resp.status} ${await resp.text()}`);
    }
  }
}
