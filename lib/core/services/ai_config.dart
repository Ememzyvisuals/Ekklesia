import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config/app_config.dart';
import 'auth_service.dart';

/// Central model-selection layer for Groq, per the "never hardcode a model"
/// build rule. GroqService reads [currentModel] instead of a literal string,
/// so swapping models — including an automatic fallback — never touches
/// business logic in GroqService itself.
///
/// Call [AIConfig.instance.verify] once at app bootstrap (before any chat UI
/// is shown). If it's never called, [currentModel] safely defaults to
/// [AppConfig.groqPreferredModel] — verify() only ever narrows to a model
/// that's confirmed available, it never widens beyond the supported list.
///
/// Checks Groq's live model list via the Cloudflare Worker proxy's
/// `/groqModels` endpoint (`cloudflare/groq-proxy/`) — migrated off the
/// Firebase `groqModels` callable specifically to avoid requiring the
/// Firebase Blaze plan for this. See that Worker's README for the
/// reasoning and verified free-tier numbers.
class AIConfig {
  AIConfig._internal();
  static final AIConfig instance = AIConfig._internal();

  String _currentModel = AppConfig.groqPreferredModel;
  String get currentModel => _currentModel;

  bool _verified = false;
  bool get isVerified => _verified;

  /// Fetches Groq's live model list (via the Cloudflare Worker's
  /// `/groqModels` endpoint) and picks the first entry from
  /// [AppConfig.groqSupportedModels] that's actually present. Falls back
  /// to the configured default (last-resort) if the call itself fails —
  /// this is deliberately optimistic rather than blocking app startup on
  /// a network call succeeding. Requires the user to already be signed
  /// in (the Worker rejects requests without a valid Firebase ID token)
  /// — if called before sign-in, this fails open the same way a network
  /// failure would.
  Future<void> verify() async {
    try {
      final idToken = await AuthService.instance.getIdToken();
      if (idToken == null) {
        _verified = false;
        return;
      }

      final response = await http.get(
        Uri.parse('${AppConfig.groqProxyBaseUrl}/groqModels'),
        headers: {'Authorization': 'Bearer $idToken'},
      ).timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        _verified = false;
        return;
      }

      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final liveIds = ((decoded['modelIds'] as List<dynamic>? ?? []))
          .whereType<String>()
          .toSet();

      for (final candidate in AppConfig.groqSupportedModels) {
        if (liveIds.contains(candidate)) {
          _currentModel = candidate;
          _verified = true;
          return;
        }
      }

      // None of the supported models are live — keep the default so chat
      // still attempts the call (Groq's own error message is more useful to
      // surface than silently disabling the feature).
      _verified = false;
    } catch (_) {
      // Not signed in yet, network failure, timeout, cold-start, etc —
      // fail open with the preferred default rather than blocking startup.
      _verified = false;
    }
  }
}
