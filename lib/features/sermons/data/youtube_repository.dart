import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;

import '../../../core/config/app_config.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/shared/result.dart';
import '../domain/video_entry.dart';

class YoutubeRepository {
  YoutubeRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  /// Reads from the Firestore cache first (fast, works offline); a fresh
  /// pull only happens via [refresh] (called by YoutubeWorker or a manual
  /// pull-to-refresh), never on every screen open — the addendum's
  /// "avoid battery drain" rule for workers applies here too.
  Future<Result<List<VideoEntry>>> getCachedUploads({String? category}) async {
    try {
      Query query = _firestore
          .collection(AppConfig.youtubeCacheCollection)
          .orderBy('published_at', descending: true);
      if (category != null) {
        query = query.where('category', isEqualTo: category);
      }
      final snapshot = await query.limit(50).get();
      final videos = snapshot.docs
          .map((doc) =>
              VideoEntry.fromFirestore(doc.data() as Map<String, dynamic>))
          .toList();
      return Result.success(videos);
    } on FirebaseException catch (e) {
      return Result.failure(AppFailure(
        message:
            'Couldn\'t load messages right now — check your connection and try again.',
        debugDetail: '${e.code}: ${e.message}',
      ));
    } catch (e) {
      return Result.failure(AppFailure(
          message: 'Something went wrong loading messages.',
          debugDetail: e.toString()));
    }
  }

  Stream<VideoEntry?> watchLiveStatus() {
    return _firestore
        .collection('config')
        .doc(AppConfig.youtubeLiveStatusDoc)
        .snapshots()
        .map((doc) {
      if (!doc.exists || doc.data() == null || doc.data()!['video_id'] == null)
        return null;
      return VideoEntry.fromFirestore(doc.data()!);
    });
  }

  /// Triggers a fresh YouTube pull and Firestore cache rewrite via the
  /// `syncNow` Cloudflare Worker endpoint (cloudflare/youtube-sync/) —
  /// the same server-side logic as `youtubeSyncSchedule`'s Cron Trigger,
  /// which runs every 15 minutes regardless of whether the app is open.
  /// Called by YoutubeWorker (on a timer / app foreground) — not on every
  /// screen build, per the addendum's worker rules.
  ///
  /// This used to call the YouTube Data API directly from the client
  /// (`YoutubeRemoteDatasource`, deleted), then went through a Firebase
  /// Cloud Function callable (`syncYoutubeNow`), and now goes through this
  /// Cloudflare Worker instead — moved specifically to avoid requiring
  /// the Firebase Blaze plan for this piece. Daily verse/prayer/cleanup
  /// and all push-notification fan-out needed the same treatment before
  /// Blaze was actually fully avoidable app-wide — see
  /// `cloudflare/daily-content/README.md` and `PHASE2_NOTES.md` for that
  /// part. See `cloudflare/youtube-sync/README.md` for the full
  /// reasoning on this Worker specifically — it still writes to
  /// Firestore with real admin-level credentials (a Google Service
  /// Account), so `firestore.rules`' server-only write rule on
  /// `youtube_videos`/`config` stays intact; this migration didn't
  /// relax that.
  Future<Result<void>> refresh() async {
    try {
      final idToken = await AuthService.instance.getIdToken();
      if (idToken == null) {
        return Result.failure(
            AppFailure(message: 'Sign in to refresh messages.'));
      }

      final response = await http.post(
        Uri.parse('${AppConfig.youtubeSyncProxyBaseUrl}/syncNow'),
        headers: {'Authorization': 'Bearer $idToken'},
      );

      if (response.statusCode != 200) {
        return Result.failure(AppFailure(
          message: 'Couldn\'t refresh messages from YouTube.',
          debugDetail: '${response.statusCode}: ${response.body}',
        ));
      }

      return const Result.success(null);
    } catch (e) {
      return Result.failure(AppFailure(
        message: 'Couldn\'t refresh messages from YouTube.',
        debugDetail: e.toString(),
      ));
    }
  }
}
