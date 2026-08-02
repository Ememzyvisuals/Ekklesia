import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/ai/data/conversation_repository.dart';
import '../../features/ai/domain/conversation.dart';

/// Queues AI chat turns for Firestore persistence and flushes them when
/// connectivity returns — the "Conversation sync" / "Conversation cache"
/// requirement. Mirrors SyncWorker's queued-write pattern rather than
/// introducing a second offline strategy for the same problem.
///
/// Scope note: like SyncWorker/YoutubeWorker, this runs on a foreground
/// timer + connectivity listener, not a true OS-level background task —
/// see YoutubeWorker's doc comment for why that's a separate follow-up
/// (needs `workmanager` platform registration, not present yet).
class ConversationWorker {
  ConversationWorker._internal();
  static final ConversationWorker instance = ConversationWorker._internal();

  static const _queueKey = 'pending_conversation_messages';

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  Timer? _retryTimer;

  void start() {
    stop();
    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      if (results.any((r) => r != ConnectivityResult.none)) {
        flushQueue();
      }
    });
    // Retry sweep in case a write silently failed without a connectivity
    // event (e.g. Firestore rules rejection during a token refresh window).
    _retryTimer = Timer.periodic(const Duration(minutes: 2), (_) => flushQueue());
    flushQueue();
  }

  void stop() {
    _connectivitySub?.cancel();
    _retryTimer?.cancel();
  }

  /// Call this immediately after a chat turn is generated/sent. Tries a
  /// direct Firestore write first; on failure, queues locally so the
  /// message survives an app restart and is retried once online.
  Future<void> record(ConversationMessage message) async {
    try {
      await ConversationRepository.instance.save(message);
    } catch (_) {
      await _enqueue(message);
    }
  }

  Future<void> flushQueue() async {
    final prefs = await SharedPreferences.getInstance();
    final lines = prefs.getStringList(_queueKey) ?? [];
    if (lines.isEmpty) return;

    final stillPending = <String>[];
    for (final line in lines) {
      final message = ConversationMessage.fromQueueLine(line);
      if (message == null) continue; // corrupt entry — drop rather than loop forever
      try {
        await ConversationRepository.instance.save(message);
      } catch (_) {
        stillPending.add(line);
      }
    }
    await prefs.setStringList(_queueKey, stillPending);
  }

  Future<void> _enqueue(ConversationMessage message) async {
    final prefs = await SharedPreferences.getInstance();
    final lines = prefs.getStringList(_queueKey) ?? [];
    lines.add(message.toQueueLine());
    await prefs.setStringList(_queueKey, lines);
  }
}
