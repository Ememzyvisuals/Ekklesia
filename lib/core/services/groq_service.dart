import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'ai_config.dart';
import 'auth_service.dart';
import 'groq_usage_service.dart';
import 'user_groq_key_service.dart';

class GroqMessage {
  const GroqMessage({required this.role, required this.content});
  final String role; // 'system' | 'user' | 'assistant'
  final String content;

  Map<String, String> toJson() => {'role': role, 'content': content};
}

/// Handles all text generation: chat replies, message summaries, and
/// quiz generation for Impact Academy. One model call type, several
/// prompt shapes.
///
/// Two call paths, chosen automatically:
///
/// 1. **Personal key set** (Settings → AI → "Your own Groq API key" —
///    see [UserGroqKeyService]): calls Groq directly with the user's own
///    key. Unlimited, doesn't touch the shared quota at all.
/// 2. **No personal key**: goes through the shared Groq proxy — a
///    Cloudflare Worker (`cloudflare/groq-proxy/`), NOT a Firebase Cloud
///    Function callable anymore. That migration happened specifically to
///    avoid requiring the Firebase Blaze plan for something this small —
///    see `cloudflare/groq-proxy/README.md`. Capped at
///    [GroqUsageService.dailyFreeLimit] calls/day per device. Once the
///    cap is hit, [chat] throws [GroqUsageLimitException] *without
///    making a network call*.
///
/// Auth for path 2 is a Firebase ID token sent as a Bearer header — the
/// Worker verifies it itself against Google's public JWKS (see that
/// README for why a plain Worker needs to do this manually, unlike a
/// Firebase callable which gets `request.auth` for free).
///
/// This used to hold GROQ_API_KEY via flutter_dotenv, which shipped the
/// key inside every app install — see PHASE2_NOTES.md for the exposure
/// this closed. Neither the earlier Cloud Functions fix nor this
/// Cloudflare migration reintroduces that — a personal key (path 1) is
/// the user's own revocable credential, and the shared key (path 2) has
/// never lived anywhere the client can read it, on either backend.
class GroqService {
  GroqService._internal();
  static final GroqService instance = GroqService._internal();

  static const _directChatUrl =
      'https://api.groq.com/openai/v1/chat/completions';

  Future<String> chat(List<GroqMessage> messages) async {
    final personalKey = await UserGroqKeyService.instance.getKey();
    if (personalKey != null) {
      return _chatWithPersonalKey(messages, personalKey);
    }
    return _chatWithSharedProxy(messages);
  }

  Future<String> _chatWithSharedProxy(List<GroqMessage> messages) async {
    if (await GroqUsageService.instance.hasReachedDailyLimit()) {
      throw GroqUsageLimitException(
          dailyLimit: GroqUsageService.dailyFreeLimit);
    }

    final idToken = await AuthService.instance.getIdToken();
    if (idToken == null) {
      throw Exception('You need to be signed in to use the AI Assistant.');
    }

    final response = await http.post(
      Uri.parse('${AppConfig.groqProxyBaseUrl}/groqChat'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $idToken',
      },
      body: jsonEncode({
        'messages': messages.map((m) => m.toJson()).toList(),
        'model': AIConfig.instance.currentModel,
      }),
    );

    if (response.statusCode == 401) {
      throw Exception('Session expired or invalid — please sign in again.');
    }
    if (response.statusCode != 200) {
      throw Exception(
          'Groq request failed (${response.statusCode}): ${response.body}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final reply = decoded['reply'];
    if (reply is! String) {
      throw Exception(
          'Groq proxy returned an unexpected shape: ${response.body}');
    }

    await GroqUsageService.instance.recordUsage();
    return reply;
  }

  Future<String> _chatWithPersonalKey(
      List<GroqMessage> messages, String apiKey) async {
    final response = await http.post(
      Uri.parse(_directChatUrl),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': AIConfig.instance.currentModel,
        'messages': messages.map((m) => m.toJson()).toList(),
      }),
    );

    if (response.statusCode == 401) {
      throw Exception(
        'Your personal Groq API key was rejected (401) — check it\'s correct in Settings, '
        'or remove it to fall back to the free shared key.',
      );
    }
    if (response.statusCode != 200) {
      throw Exception(
          'Groq request failed (${response.statusCode}): ${response.body}');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final choices = decoded['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      throw Exception('Groq returned an unexpected shape: ${response.body}');
    }
    final content =
        (choices.first as Map<String, dynamic>)['message']?['content'];
    if (content is! String) {
      throw Exception(
          'Groq returned an unexpected message shape: ${response.body}');
    }
    return content;
  }

  /// Generates a short bullet-point summary of a sermon/message transcript.
  Future<String> summarizeMessage(String transcript) {
    return chat([
      GroqMessage(
        role: 'system',
        content: 'You summarize Christian sermon transcripts into 3-5 short, '
            'clear bullet points highlighting the key teaching points. '
            'Keep language simple and direct.',
      ),
      GroqMessage(role: 'user', content: transcript),
    ]);
  }

  /// Generates a JSON-only multiple-choice quiz from a transcript.
  /// Returns the raw JSON string — parse with [parseQuizJson].
  Future<String> generateQuiz(String transcript, {int questionCount = 5}) {
    return chat([
      GroqMessage(
        role: 'system',
        content: 'You generate multiple-choice quiz questions from a sermon '
            'transcript. Respond with ONLY valid JSON, no markdown fences, '
            'no preamble. Shape: '
            '{"questions": [{"question": "...", "options": ["...","...","...","..."], '
            '"correctIndex": 0}]}. Generate exactly $questionCount questions.',
      ),
      GroqMessage(role: 'user', content: transcript),
    ]);
  }

  List<Map<String, dynamic>> parseQuizJson(String rawJson) {
    final cleaned =
        rawJson.replaceAll('```json', '').replaceAll('```', '').trim();
    final decoded = jsonDecode(cleaned) as Map<String, dynamic>;
    return (decoded['questions'] as List<dynamic>).cast<Map<String, dynamic>>();
  }
}
