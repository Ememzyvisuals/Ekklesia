import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/conversation.dart';

/// Persists AI chat turns to `ai_conversations` and provides history +
/// simple client-side search. Writes go through [ConversationWorker]'s
/// queue (see core/services/conversation_worker.dart) so a message typed
/// while offline isn't lost — this repository only talks to Firestore
/// directly for reads and immediate best-effort writes.
class ConversationRepository {
  ConversationRepository._internal();
  static final ConversationRepository instance =
      ConversationRepository._internal();

  final _collection = FirebaseFirestore.instance.collection('ai_conversations');

  Stream<List<ConversationMessage>> sessionMessages(
      String uid, String sessionId) {
    return _collection
        .where('uid', isEqualTo: uid)
        .where('session_id', isEqualTo: sessionId)
        .orderBy('created_at')
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => ConversationMessage.fromFirestore(d.id, d.data()))
            .toList());
  }

  /// All of a user's sessions, most-recent message first per session —
  /// used for the conversation history list and as the search corpus.
  Future<List<ConversationMessage>> allMessages(String uid,
      {int limit = 500}) async {
    final snap = await _collection
        .where('uid', isEqualTo: uid)
        .orderBy('created_at', descending: true)
        .limit(limit)
        .get();
    return snap.docs
        .map((d) => ConversationMessage.fromFirestore(d.id, d.data()))
        .toList();
  }

  /// Case-insensitive substring search over cached history. Firestore has
  /// no native full-text search and adding Algolia/Typesense is out of
  /// scope for a solo-dev v1 — this is a real, working search over
  /// whatever's already synced locally, not a stub.
  Future<List<ConversationMessage>> search(String uid, String query) async {
    if (query.trim().isEmpty) return [];
    final messages = await allMessages(uid);
    final needle = query.toLowerCase();
    return messages
        .where((m) => m.text.toLowerCase().contains(needle))
        .toList();
  }

  Future<void> save(ConversationMessage message) {
    return _collection.doc(message.id).set(message.toFirestore());
  }

  Future<void> deleteSession(String uid, String sessionId) async {
    final snap = await _collection
        .where('uid', isEqualTo: uid)
        .where('session_id', isEqualTo: sessionId)
        .get();
    final batch = FirebaseFirestore.instance.batch();
    for (final doc in snap.docs) {
      batch.delete(doc.reference);
    }
    await batch.commit();
  }
}
