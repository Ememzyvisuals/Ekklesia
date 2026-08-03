/**
 * Ported from functions/src/groq.ts, native fetch instead of node-fetch.
 * This Worker calls Groq's API directly with its own GROQ_API_KEY secret
 * — it does NOT go through cloudflare/groq-proxy/, because that Worker's
 * auth model (a Firebase ID token from a signed-in user) doesn't fit a
 * server-to-server scheduled job with no user in the loop. Two Workers
 * end up holding a Groq key as a result — an accepted tradeoff, not an
 * oversight; see this Worker's README.md.
 */

const GROQ_CHAT_URL = 'https://api.groq.com/openai/v1/chat/completions';

// Mirrors AppConfig.groqPreferredModel/groqFallbackModel — hand-synced,
// same caveat as config.ts's header comment.
const PREFERRED_MODEL = 'llama-3.3-70b-versatile';
const FALLBACK_MODEL = 'llama-3.1-8b-instant';

export interface GroqChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

export async function callGroq(messages: GroqChatMessage[], apiKey: string): Promise<string> {
  for (const model of [PREFERRED_MODEL, FALLBACK_MODEL]) {
    try {
      const res = await fetch(GROQ_CHAT_URL, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${apiKey}` },
        body: JSON.stringify({ model, messages, temperature: 0.7 }),
      });
      if (!res.ok) continue;
      const json = (await res.json()) as { choices?: Array<{ message?: { content?: string } }> };
      const content = json.choices?.[0]?.message?.content;
      if (content) return content;
    } catch {
      // try next model
    }
  }
  throw new Error('Groq request failed on both preferred and fallback models.');
}
