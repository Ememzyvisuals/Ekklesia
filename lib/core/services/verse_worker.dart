import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'isar_service.dart';
import '../../features/bible/data/bible_repository.dart';

/// Ensures today's verse exists in Firestore ([AppConfig.dailyVerseCollection],
/// one doc per date `yyyy-MM-dd`) and caches it locally for offline reading.
///
/// Honest scope note: the spec's architecture wants a Cloud Scheduler +
/// Cloud Function generating this server-side once daily, independent of
/// whether any client opens the app that day. That doesn't exist yet
/// (Phase 2 — no Cloud Functions in this repo). Until it does, this worker
/// is a client-side stand-in: the first client to open the app on a given
/// date generates and writes the doc; every other client (and every later
/// open that same day) just reads it. The Firestore schema below is the
/// one a future Cloud Function should write to, so migrating later is a
/// drop-in — no client changes needed once the scheduled function exists.
class VerseWorker {
  VerseWorker._internal();
  static final VerseWorker instance = VerseWorker._internal();

  static const _cacheKey = 'cached_daily_verse';
  static const _cacheDateKey = 'cached_daily_verse_date';

  final _collection =
      FirebaseFirestore.instance.collection(AppConfig.dailyVerseCollection);

  /// Returns today's verse: cache -> Firestore -> generate-and-write ->
  /// last-resort local fallback if fully offline with no prior cache.
  Future<Map<String, dynamic>> getTodaysVerse(
      {required String language}) async {
    final today = _todayKey();
    final prefs = await SharedPreferences.getInstance();

    if (prefs.getString(_cacheDateKey) == today) {
      final cached = prefs.getString(_cacheKey);
      if (cached != null)
        return {'reference': cached, 'language': language, 'source': 'cache'};
    }

    try {
      final doc = await _collection.doc(today).get();
      if (doc.exists && doc.data() != null) {
        final reference = doc.data()!['reference'] as String;
        await _cacheLocally(today, reference);
        return {
          'reference': reference,
          'language': language,
          'source': 'firestore'
        };
      }
      return await _generateAndStore(today, language);
    } catch (_) {
      // Offline and no prior cache for today — deterministic pick from the
      // fallback list so at least every device shows the same verse.
      final fallback = AppConfig.verseFallbackReferences[
          DateTime.now().day % AppConfig.verseFallbackReferences.length];
      return {
        'reference': fallback,
        'language': language,
        'source': 'offline_fallback'
      };
    }
  }

  Future<Map<String, dynamic>> _generateAndStore(
      String dateKey, String language) async {
    final random = Random(dateKey.hashCode);
    final reference = AppConfig.verseFallbackReferences[
        random.nextInt(AppConfig.verseFallbackReferences.length)];

    try {
      // Fetch the actual text once so the stored doc is immediately useful
      // to other clients/languages without each re-parsing the reference.
      // Reads from the offline Isar-backed Bible engine — falls through to
      // the reference-only doc below if English hasn't been imported on
      // this device yet (import is on-demand per-language, not guaranteed
      // at first launch).
      final repo = BibleRepository(IsarService.instance.isar);
      final verses = await repo.getPassage(reference, language: 'en');
      final text =
          verses.map((v) => v.text ?? '').where((t) => t.isNotEmpty).join(' ');
      await _collection.doc(dateKey).set({
        'reference': reference,
        'text_en': text,
        'generated_at': FieldValue.serverTimestamp(),
        'source': 'client_v1',
      });
    } catch (_) {
      await _collection.doc(dateKey).set({
        'reference': reference,
        'generated_at': FieldValue.serverTimestamp(),
        'source': 'client_v1',
      });
    }

    await _cacheLocally(dateKey, reference);
    return {
      'reference': reference,
      'language': language,
      'source': 'generated'
    };
  }

  Future<void> _cacheLocally(String dateKey, String reference) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey, reference);
    await prefs.setString(_cacheDateKey, dateKey);
  }

  String _todayKey() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }
}
