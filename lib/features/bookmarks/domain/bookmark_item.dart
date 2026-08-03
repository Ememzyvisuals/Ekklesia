/// What kind of content a bookmark points at — determines how
/// BookmarksScreen navigates when a bookmark is tapped, since each type
/// needs different data to reopen (a Bible reference + language vs. a
/// full VideoEntry vs. an AI conversation session id).
enum BookmarkType { bible, sermon, aiConversation }

extension BookmarkTypeName on BookmarkType {
  String get wireName {
    switch (this) {
      case BookmarkType.bible:
        return 'bible';
      case BookmarkType.sermon:
        return 'sermon';
      case BookmarkType.aiConversation:
        return 'ai_conversation';
    }
  }

  static BookmarkType fromWireName(String name) {
    switch (name) {
      case 'sermon':
        return BookmarkType.sermon;
      case 'ai_conversation':
        return BookmarkType.aiConversation;
      case 'bible':
      default:
        return BookmarkType.bible;
    }
  }
}

/// A saved reference to Bible content, a sermon/program, or an AI
/// conversation session — per the spec's "Bookmarks: Bible, Programs,
/// Messages, AI conversations" requirement (Downloads has its own
/// separate save-for-offline mechanism in DownloadWorker; a bookmark is
/// a lightweight pointer, not an offline copy).
class BookmarkItem {
  const BookmarkItem({
    required this.id,
    required this.uid,
    required this.type,
    required this.refId,
    required this.title,
    this.subtitle = '',
    this.language,
    required this.createdAt,
  });

  final String id;
  final String uid;
  final BookmarkType type;

  /// Bible: the reference string (e.g. "John 3:16"). Sermon: the YouTube
  /// video id. AI conversation: the session id (see
  /// ConversationMessage.sessionId).
  final String refId;

  final String title;
  final String subtitle;

  /// Only meaningful for [BookmarkType.bible] — which language/version to
  /// reopen the reference in.
  final String? language;

  final DateTime createdAt;

  /// Deterministic id so bookmarking the same content twice updates the
  /// same doc instead of creating a duplicate — a repeated tap on the
  /// bookmark button is a toggle, not an accumulator.
  static String deterministicId(String uid, BookmarkType type, String refId) =>
      '${uid}_${type.wireName}_$refId';

  factory BookmarkItem.fromFirestore(String id, Map<String, dynamic> data) =>
      BookmarkItem(
        id: id,
        uid: data['uid'] as String,
        type: BookmarkTypeName.fromWireName(data['type'] as String? ?? 'bible'),
        refId: data['ref_id'] as String,
        title: data['title'] as String? ?? '',
        subtitle: data['subtitle'] as String? ?? '',
        language: data['language'] as String?,
        createdAt: (data['created_at'] is String)
            ? DateTime.tryParse(data['created_at'] as String) ?? DateTime.now()
            : DateTime.now(),
      );

  Map<String, dynamic> toFirestore() => {
        'uid': uid,
        'type': type.wireName,
        'ref_id': refId,
        'title': title,
        'subtitle': subtitle,
        if (language != null) 'language': language,
        'created_at': createdAt.toIso8601String(),
      };
}
