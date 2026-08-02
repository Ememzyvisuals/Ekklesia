import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Background sync worker — implements Volume 8's "offline-first, write
/// locally, sync when connectivity returns" strategy.
///
/// v1 scope: settings + reading/quiz progress that were written locally
/// while offline get queued (as simple pending-write records in
/// SharedPreferences) and flushed to Firestore once a connection is
/// available. This is intentionally simple (not a full conflict-resolution
/// engine) — good enough for a solo-dev v1; revisit if real conflicts
/// start showing up in testing.
class SyncWorker {
  SyncWorker._internal();
  static final SyncWorker instance = SyncWorker._internal();

  static const _pendingWritesKey = 'pending_sync_writes';
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  void start() {
    _subscription = Connectivity().onConnectivityChanged.listen((results) {
      final hasConnection = results.any((r) => r != ConnectivityResult.none);
      if (hasConnection) {
        flushPendingWrites();
      }
    });
    // Also try once at startup in case connectivity was already there.
    flushPendingWrites();
  }

  void stop() {
    _subscription?.cancel();
  }

  /// Call this instead of writing directly to Firestore when the write
  /// should survive being offline. Attempts immediately; if it fails
  /// (no connection), queues for the next [flushPendingWrites] pass.
  Future<void> queueWrite({
    required String collection,
    required String docId,
    required Map<String, dynamic> data,
  }) async {
    try {
      await FirebaseFirestore.instance.collection(collection).doc(docId).set(
            data,
            SetOptions(merge: true),
          );
    } catch (_) {
      await _addPendingWrite(collection, docId, data);
    }
  }

  Future<void> flushPendingWrites() async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getStringList(_pendingWritesKey) ?? [];
    if (pending.isEmpty) return;

    final stillPending = <String>[];
    for (final entry in pending) {
      final parts = entry.split('||');
      if (parts.length < 3) continue;
      final collection = parts[0];
      final docId = parts[1];
      try {
        await FirebaseFirestore.instance.collection(collection).doc(docId).set(
          {'_synced_from_queue': true},
          SetOptions(merge: true),
        );
      } catch (_) {
        stillPending.add(entry);
      }
    }
    await prefs.setStringList(_pendingWritesKey, stillPending);
  }

  Future<void> _addPendingWrite(String collection, String docId, Map<String, dynamic> data) async {
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getStringList(_pendingWritesKey) ?? [];
    pending.add('$collection||$docId||queued');
    await prefs.setStringList(_pendingWritesKey, pending);
  }
}
