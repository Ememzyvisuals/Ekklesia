/// A single persisted AI chat turn — collection: `ai_conversations`.
///
/// The AI assistant screen previously kept chat history in in-memory
/// `State` only (lost on app restart, no cross-device sync, no search).
/// This model + ConversationRepository/ConversationWorker close that gap
/// per the spec's "Conversation sync / cache / search" requirement.
class ConversationMessage {
  const ConversationMessage({
    required this.id,
    required this.uid,
    required this.sessionId,
    required this.role,
    required this.text,
    required this.createdAt,
    this.synced = true,
  });

  final String id;
  final String uid;

  /// Groups messages into one continuous chat thread. A new sessionId is
  /// started when the user explicitly starts a new conversation; otherwise
  /// the app reuses the most recent open session for that day.
  final String sessionId;

  final String role; // 'user' | 'assistant'
  final String text;
  final DateTime createdAt;

  /// False while queued locally and not yet written to Firestore (offline).
  final bool synced;

  factory ConversationMessage.fromFirestore(String id, Map<String, dynamic> data) {
    return ConversationMessage(
      id: id,
      uid: data['uid'] as String? ?? '',
      sessionId: data['session_id'] as String? ?? '',
      role: data['role'] as String? ?? 'user',
      text: data['text'] as String? ?? '',
      createdAt: (data['created_at'] is String)
          ? DateTime.tryParse(data['created_at'] as String) ?? DateTime.now()
          : DateTime.now(),
      synced: true,
    );
  }

  Map<String, dynamic> toFirestore() => {
        'uid': uid,
        'session_id': sessionId,
        'role': role,
        'text': text,
        'created_at': createdAt.toIso8601String(),
      };

  /// Cheap local encode/decode for the SharedPreferences offline queue —
  /// intentionally not JSON via dart:convert's full Map machinery here since
  /// the fields are flat strings; keeps ConversationWorker dependency-free
  /// beyond shared_preferences, matching SyncWorker's existing pattern.
  String toQueueLine() =>
      '$id\u0001$uid\u0001$sessionId\u0001$role\u0001${text.replaceAll('\n', '\u0002')}\u0001${createdAt.toIso8601String()}';

  static ConversationMessage? fromQueueLine(String line) {
    final parts = line.split('\u0001');
    if (parts.length < 6) return null;
    return ConversationMessage(
      id: parts[0],
      uid: parts[1],
      sessionId: parts[2],
      role: parts[3],
      text: parts[4].replaceAll('\u0002', '\n'),
      createdAt: DateTime.tryParse(parts[5]) ?? DateTime.now(),
      synced: false,
    );
  }
}
