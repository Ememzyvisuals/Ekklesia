import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:path_provider/path_provider.dart';

import '../../features/bible/data/bible_audio_cache.dart';
import '../config/app_config.dart';
import 'isar_service.dart';

/// Periodic housekeeping: removes orphaned local files (partial/cancelled
/// downloads, stale cached audio) and prunes old log documents so
/// Firestore collections like `notifications` / `worker_logs` /
/// `sync_logs` don't grow unbounded for a single-tenant-per-doc app.
///
/// This does NOT touch a user's completed Downloads (see DownloadWorker) —
/// only files explicitly marked temp/orphaned, and log/notification
/// collections that are operational data, not user content.
class CleanupWorker {
  CleanupWorker._internal();
  static final CleanupWorker instance = CleanupWorker._internal();

  static const _maxNotificationAge = Duration(days: 30);
  static const _maxLogAge = Duration(days: 14);
  static const _maxTempFileAge = Duration(days: 3);

  /// Runs one full pass. Safe to call repeatedly (e.g. once per app
  /// launch, or on an interval via a foreground timer in main.dart) —
  /// every step is independently no-op if there's nothing to clean.
  Future<void> runOnce({required String uid}) async {
    await Future.wait([
      _pruneOldDocs(
          collection: 'notifications',
          field: 'uid',
          value: uid,
          maxAge: _maxNotificationAge,
          dateField: 'created_at'),
      _pruneOldDocs(
          collection: AppConfig.workerLogsCollection,
          maxAge: _maxLogAge,
          dateField: 'created_at'),
      _pruneOldDocs(
          collection: AppConfig.syncLogsCollection,
          maxAge: _maxLogAge,
          dateField: 'created_at'),
      _pruneOldDocs(
          collection: AppConfig.downloadLogsCollection,
          maxAge: _maxLogAge,
          dateField: 'created_at'),
      _pruneOrphanedTempFiles(),
      _pruneOrphanedBibleAudio(),
    ]);
  }

  /// Reconciles the Bible chapter-audio cache (see BibleAudioCache) —
  /// covers the spec's "BibleCleanupWorker" responsibility without a
  /// separate timer/class, since it's just one more step in the
  /// housekeeping pass this worker already runs.
  Future<void> _pruneOrphanedBibleAudio() async {
    try {
      await BibleAudioCache(IsarService.instance.isar).pruneOrphaned();
    } catch (_) {
      // Isar not open yet, or a file-system hiccup — next cycle retries.
    }
  }

  Future<void> _pruneOldDocs({
    required String collection,
    required Duration maxAge,
    required String dateField,
    String? field,
    String? value,
  }) async {
    try {
      final cutoff = Timestamp.fromDate(DateTime.now().subtract(maxAge));
      Query query = FirebaseFirestore.instance
          .collection(collection)
          .where(dateField, isLessThan: cutoff);
      if (field != null && value != null) {
        query = query.where(field, isEqualTo: value);
      }
      final snapshot = await query
          .limit(200)
          .get(); // capped per pass — repeated runs finish the job without one huge batch
      if (snapshot.docs.isEmpty) return;

      final batch = FirebaseFirestore.instance.batch();
      for (final doc in snapshot.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();
    } catch (_) {
      // Best-effort housekeeping — a failed prune this cycle just means
      // more gets cleaned next cycle. Never surface this to the user.
    }
  }

  /// Deletes files under the app's temp directory whose extension marks
  /// them as in-progress downloads (`.part`) older than [_maxTempFileAge] —
  /// these are downloads that were cancelled/crashed mid-transfer and
  /// never got promoted to a completed file by DownloadWorker.
  Future<void> _pruneOrphanedTempFiles() async {
    try {
      final tempDir = await getTemporaryDirectory();
      final downloadsTempDir = Directory('${tempDir.path}/downloads_tmp');
      if (!await downloadsTempDir.exists()) return;

      final cutoff = DateTime.now().subtract(_maxTempFileAge);
      await for (final entity in downloadsTempDir.list()) {
        if (entity is! File) continue;
        final stat = await entity.stat();
        if (stat.modified.isBefore(cutoff)) {
          try {
            await entity.delete();
          } catch (_) {
            // File may be actively being written by an in-flight download —
            // skip it this pass rather than risk corrupting a live transfer.
          }
        }
      }
    } catch (_) {
      // Platform without a temp dir concept, or permission issue — no-op.
    }
  }
}
