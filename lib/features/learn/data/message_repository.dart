import 'package:cloud_firestore/cloud_firestore.dart';

/// A single archived message (sermon/teaching) shown in Impact Academy.
///
/// Collection: `messages` (transcript + metadata, seeded by an admin
/// process — not user-generated). Summary/quiz are generated on first
/// request and cached back onto the same document so repeat visits
/// don't re-call Groq unnecessarily.
class ArchivedMessage {
  ArchivedMessage({
    required this.id,
    required this.title,
    required this.category,
    required this.transcript,
    this.summary,
    this.quiz,
  });

  final String id;
  final String title;
  final String
      category; // Sunday Service | Bible Study | GCK | Programs | Impact Academy
  final String transcript;
  final String? summary;
  final List<Map<String, dynamic>>? quiz;

  factory ArchivedMessage.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ArchivedMessage(
      id: doc.id,
      title: data['title'] as String? ?? 'Untitled',
      category: data['category'] as String? ?? 'Programs',
      transcript: data['transcript'] as String? ?? '',
      summary: data['summary'] as String?,
      quiz: (data['quiz'] as List<dynamic>?)?.cast<Map<String, dynamic>>(),
    );
  }
}

class MessageRepository {
  MessageRepository._internal();
  static final MessageRepository instance = MessageRepository._internal();

  final _messages = FirebaseFirestore.instance.collection('messages');

  Future<List<ArchivedMessage>> getByCategory(String category) async {
    final snapshot = await _messages
        .where('category', isEqualTo: category)
        .orderBy('created_at', descending: true)
        .get();
    return snapshot.docs.map(ArchivedMessage.fromFirestore).toList();
  }

  Future<void> saveSummary(String messageId, String summary) {
    return _messages.doc(messageId).update({'summary': summary});
  }

  Future<void> saveQuiz(String messageId, List<Map<String, dynamic>> quiz) {
    return _messages.doc(messageId).update({'quiz': quiz});
  }

  /// Records a completed quiz attempt under the user's own subtree, per
  /// Volume 8's `quiz_progress` collection and per-user write scoping.
  Future<void> recordQuizAttempt({
    required String uid,
    required String messageId,
    required int score,
    required int totalQuestions,
  }) {
    return FirebaseFirestore.instance.collection('quiz_progress').add({
      'uid': uid,
      'message_id': messageId,
      'score': score,
      'total_questions': totalQuestions,
      'completed_at': FieldValue.serverTimestamp(),
    });
  }
}
