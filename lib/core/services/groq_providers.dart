import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'groq_usage_service.dart';
import 'user_groq_key_service.dart';

/// The user's personal Groq key, if set. `autoDispose` + explicit
/// `ref.invalidate(userGroqKeyProvider)` after save/clear (see
/// settings_screen.dart) is what makes the Settings UI actually refresh —
/// a bare `FutureBuilder` re-calling `UserGroqKeyService.instance.getKey()`
/// on every rebuild looks like it would refresh too, but nothing in a
/// stateless/Consumer widget *triggers* a rebuild after a dialog closes,
/// so it was silently showing stale data until the screen was
/// re-entered. Routing through a provider gives an explicit invalidation
/// point instead of relying on an unrelated rebuild to happen to occur.
final userGroqKeyProvider = FutureProvider.autoDispose<String?>((ref) {
  return UserGroqKeyService.instance.getKey();
});

final groqRemainingTodayProvider = FutureProvider.autoDispose<int>((ref) {
  return GroqUsageService.instance.getRemainingToday();
});
