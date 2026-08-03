import 'package:shared_preferences/shared_preferences.dart';

/// Stores a personal Groq API key the user got themselves from
/// console.groq.com/keys, so [GroqService] can call Groq directly with
/// it instead of going through the shared `groqChat` Cloudflare Worker
/// endpoint (and instead of counting against [GroqUsageService]'s daily
/// cap on the shared key).
///
/// This is NOT the same security concern the Groq/YouTube Cloud Functions
/// migration (see PHASE2_NOTES.md) closed. That migration was about a
/// *shared secret* shipping inside every app install, where any user
/// could extract it and abuse it on the app's account. A personal key
/// here is different: it's a credential the user obtained themselves,
/// they explicitly typed it into their own device's Settings, and only
/// their own device/account is affected if it leaks. Storing it locally
/// via SharedPreferences (not Secret Manager, not synced to Firestore) is
/// the right tradeoff for that — a lighter persistence choice than
/// `flutter_secure_storage` would give (which isn't currently a project
/// dependency), acceptable specifically because it's the user's own
/// revocable key, not a shared production secret.
class UserGroqKeyService {
  UserGroqKeyService._internal();
  static final UserGroqKeyService instance = UserGroqKeyService._internal();

  static const _key = 'user_groq_api_key';

  Future<String?> getKey() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(_key);
    return (value == null || value.trim().isEmpty) ? null : value.trim();
  }

  Future<bool> hasKey() async => (await getKey()) != null;

  Future<void> setKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      await clearKey();
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, trimmed);
  }

  Future<void> clearKey() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  /// Masks a key for display — e.g. "gsk_...a1B2" — never show the full
  /// key back once saved.
  static String mask(String key) {
    if (key.length <= 8) return '••••••••';
    return '${key.substring(0, 4)}...${key.substring(key.length - 4)}';
  }
}
