import { onCall, HttpsError } from "firebase-functions/v2/https";
import fetch from "node-fetch";
import { callGroq, groqApiKeySecret, GroqChatMessage } from "./groq";

const GROQ_MODELS_URL = "https://api.groq.com/openai/v1/models";

/**
 * Server-side stand-in for GroqService.chat()'s direct-to-Groq call.
 * Closes the exposure PrayerWorker's doc comment flags explicitly: today
 * GroqService reads GROQ_API_KEY out of the app's bundled .env, which
 * means the key ships inside every install. This callable does the same
 * job without the client ever holding the key.
 *
 * Not wired into GroqService yet in this pass — see PHASE2_NOTES.md for
 * the two-line change that switches GroqService.chat() to call this via
 * `cloud_functions` instead of `http` + `dotenv`, and what to remove from
 * .env once it's confirmed working end-to-end.
 */
export const groqChat = onCall(
  { region: "us-central1", secrets: [groqApiKeySecret] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }

    const messages = request.data?.messages as GroqChatMessage[] | undefined;
    if (!Array.isArray(messages) || messages.length === 0) {
      throw new HttpsError("invalid-argument", "`messages` must be a non-empty array.");
    }
    for (const m of messages) {
      if (!["system", "user", "assistant"].includes(m.role) || typeof m.content !== "string") {
        throw new HttpsError("invalid-argument", "Each message needs a valid role and string content.");
      }
    }

    try {
      const reply = await callGroq(messages, groqApiKeySecret.value());
      return { reply };
    } catch (e) {
      throw new HttpsError("internal", `Groq request failed: ${e}`);
    }
  }
);

/**
 * Server-side stand-in for AIConfig.verify()'s direct-to-Groq models call
 * — same exposure, same fix shape. Returns the live model ids so the
 * client can still do its own "pick the first supported one" logic
 * without needing the key to ask the question.
 */
export const groqModels = onCall(
  { region: "us-central1", secrets: [groqApiKeySecret] },
  async (request) => {
    if (!request.auth) {
      throw new HttpsError("unauthenticated", "Sign-in required.");
    }
    try {
      const res = await fetch(GROQ_MODELS_URL, {
        headers: { Authorization: `Bearer ${groqApiKeySecret.value()}` },
      });
      if (!res.ok) throw new Error(`Groq models ${res.status}`);
      const json = (await res.json()) as { data?: Array<{ id?: string }> };
      const ids = (json.data ?? []).map((m) => m.id).filter((id): id is string => !!id);
      return { modelIds: ids };
    } catch (e) {
      throw new HttpsError("internal", `Groq models request failed: ${e}`);
    }
  }
);
