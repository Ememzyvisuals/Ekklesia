import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/config/app_config.dart';
import '../domain/bookmark_item.dart';

/// Persists bookmarks to Firestore. Deliberately simple — no local cache
/// layer of its own, since [BookmarksScreen] reads via a live `snapshots()`
/// stream (Firestore's SDK already caches the last snapshot on disk and
/// serves it instantly offline, then reconciles when connectivity
/// returns — a second hand-rolled cache on top would just be duplicate
/// bookkeeping for the same guarantee the SDK already gives for free).
class BookmarkRepository {
  BookmarkRepository._internal();
  static final BookmarkRepository instance = BookmarkRepository._internal();

  final _collection =
      FirebaseFirestore.instance.collection(AppConfig.bookmarksCollection);

  Stream<List<BookmarkItem>> watchAll(String uid) {
    return _collection
        .where('uid', isEqualTo: uid)
        .orderBy('created_at', descending: true)
        .snapshots()
        .map((snap) => snap.docs
            .map((d) => BookmarkItem.fromFirestore(d.id, d.data()))
            .toList());
  }

  /// One-shot lookup for a single bookmark button's initial state —
  /// avoids every BookmarkButton instance on a list screen (e.g. the
  /// sermon library) subscribing to the whole bookmarks collection just
  /// to know if its one item is saved.
  Future<bool> isBookmarked(String uid, BookmarkType type, String refId) async {
    final doc = await _collection
        .doc(BookmarkItem.deterministicId(uid, type, refId))
        .get();
    return doc.exists;
  }

  Future<void> add(BookmarkItem item) {
    final id = BookmarkItem.deterministicId(item.uid, item.type, item.refId);
    return _collection.doc(id).set(item.toFirestore());
  }

  Future<void> remove(String uid, BookmarkType type, String refId) {
    final id = BookmarkItem.deterministicId(uid, type, refId);
    return _collection.doc(id).delete();
  }

  Future<bool> toggle(BookmarkItem item) async {
    final isSaved = await isBookmarked(item.uid, item.type, item.refId);
    if (isSaved) {
      await remove(item.uid, item.type, item.refId);
      return false;
    } else {
      await add(item);
      return true;
    }
  }
}
