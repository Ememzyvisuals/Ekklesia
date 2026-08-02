import fetch from "node-fetch";
import { defineSecret } from "firebase-functions/params";

// Set with: firebase functions:secrets:set GROQ_API_KEY
export const groqApiKeySecret = defineSecret("GROQ_API_KEY");

const GROQ_CHAT_URL = "https://api.groq.com/openai/v1/chat/completions";

// Mirrors AppConfig.groqPreferredModel/groqFallbackModel — kept in sync
// manually, same caveat as config.ts's COLLECTIONS constant.
const PREFERRED_MODEL = "llama-3.3-70b-versatile";
const FALLBACK_MODEL = "llama-3.1-8b-instant";

export interface GroqChatMessage {
  role: "system" | "user" | "assistant";
  content: string;
}

/**
 * Calls Groq with the preferred model, retrying once against the fallback
 * model on any non-2xx response (mirrors AIConfig's client-side
 * primary/fallback logic, server-side now). Throws on total failure — the
 * caller (dailyPrayer's own catch, or the callable proxy's HttpsError
 * wrapper) decides how to surface that.
 */
export async function callGroq(messages: GroqChatMessage[], apiKey: string): Promise<string> {
  for (const model of [PREFERRED_MODEL, FALLBACK_MODEL]) {
    try {
      const res = await fetch(GROQ_CHAT_URL, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${apiKey}`,
        },
        body: JSON.stringify({ model, messages, temperature: 0.7 }),
      });
      if (!res.ok) continue;
      const json = (await res.json()) as {
        choices?: Array<{ message?: { content?: string } }>;
      };
      const content = json.choices?.[0]?.message?.content;
      if (content) return content;
    } catch {
      // try next model
    }
  }
  throw new Error("Groq request failed on both preferred and fallback models.");
}
