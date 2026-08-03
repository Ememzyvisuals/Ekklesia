import 'package:shared_preferences/shared_preferences.dart';

/// Caps how many AI chat calls a person can make per day through the
/// app's *shared* Groq key (via the `groqChat` Cloudflare Worker endpoint) before
/// asking them to add their own free key from console.groq.com. Groq's
/// free tier has real per-day request limits on the shared account — this
/// protects that shared quota from being exhausted by a small number of
/// heavy users and taking chat down for everyone else, while still
/// letting anyone with their own key use the app without any cap (see
/// [UserGroqKeyService] — when a personal key is set, this limit doesn't
/// apply at all, GroqService bypasses the shared callable entirely).
///
/// Local-only (SharedPreferences), not synced to Firestore — this is a
/// soft, per-device nudge toward bringing your own key, not a hard
/// server-enforced quota. A determined person could reinstall the app or
/// clear data to reset it; that's an acceptable tradeoff for a free
/// community feature, not something worth a server-side quota system for.
class GroqUsageService {
  GroqUsageService._internal();
  static final GroqUsageService instance = GroqUsageService._internal();

  static const dailyFreeLimit = 20;

  static const _keyDate = 'groq_usage_date';
  static const _keyCount = 'groq_usage_count';

  String _todayKey() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }

  Future<int> getUsedToday() async {
    final prefs = await SharedPreferences.getInstance();
    final storedDate = prefs.getString(_keyDate);
    if (storedDate != _todayKey())
      return 0; // new day — previous count doesn't carry over
    return prefs.getInt(_keyCount) ?? 0;
  }

  Future<int> getRemainingToday() async {
    final used = await getUsedToday();
    final remaining = dailyFreeLimit - used;
    return remaining < 0 ? 0 : remaining;
  }

  Future<bool> hasReachedDailyLimit() async {
    return (await getUsedToday()) >= dailyFreeLimit;
  }

  /// Call after every successful shared-key `groqChat` call. Does nothing
  /// (and shouldn't be called) when the user has their own key — that
  /// path never touches this counter.
  Future<void> recordUsage() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _todayKey();
    final storedDate = prefs.getString(_keyDate);
    final currentCount =
        storedDate == today ? (prefs.getInt(_keyCount) ?? 0) : 0;
    await prefs.setString(_keyDate, today);
    await prefs.setInt(_keyCount, currentCount + 1);
  }
}

/// Thrown by GroqService.chat() when the shared-key daily limit is hit
/// and no personal key is configured — carries enough info for the UI to
/// show an actionable message rather than a generic error.
class GroqUsageLimitException implements Exception {
  GroqUsageLimitException({required this.dailyLimit});
  final int dailyLimit;

  @override
  String toString() =>
      'GroqUsageLimitException: daily free limit of $dailyLimit reached. '
      'Add a personal Groq API key in Settings for unlimited access.';
}
