import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/app_config.dart';
import 'groq_service.dart';
import 'verse_worker.dart';

/// Ensures today's prayer exists in Firestore ([AppConfig.dailyPrayerCollection],
/// one doc per date `yyyy-MM-dd`), generated from today's verse via Groq.
///
/// Same scope note as VerseWorker: this is the client-side stand-in for
/// what should eventually be a Cloud Scheduler + Cloud Function pipeline
/// (dailyPrayerSchedule, see PHASE2_NOTES.md — it exists and does this
/// same job server-side; this client path is the fallback if that
/// scheduled run is ever missed, same relationship VerseWorker has with
/// dailyVerseSchedule). GroqService itself no longer holds the Groq API
/// key — calls go through the `groqChat` Cloud Function callable, so this
/// path doesn't reintroduce the key-exposure issue that used to apply here.
class PrayerWorker {
  PrayerWorker._internal();
  static final PrayerWorker instance = PrayerWorker._internal();

  static const _cacheKey = 'cached_daily_prayer';
  static const _cacheDateKey = 'cached_daily_prayer_date';

  final _collection = FirebaseFirestore.instance.collection(AppConfig.dailyPrayerCollection);

  Future<Map<String, dynamic>> getTodaysPrayer({required String language}) async {
    final today = _todayKey();
    final prefs = await SharedPreferences.getInstance();

    if (prefs.getString(_cacheDateKey) == today) {
      final cached = prefs.getString(_cacheKey);
      if (cached != null) return {'text': cached, 'source': 'cache'};
    }

    try {
      final doc = await _collection.doc(today).get();
      if (doc.exists && doc.data()?['text'] != null) {
        final text = doc.data()!['text'] as String;
        await _cacheLocally(today, text);
        return {'text': text, 'source': 'firestore'};
      }
      return await _generateAndStore(today, language);
    } catch (_) {
      return {
        'text':
            'Lord, thank You for this day. Guide my steps, renew my strength, '
            'and help me walk in Your word. Amen.',
        'source': 'offline_fallback',
      };
    }
  }

  Future<Map<String, dynamic>> _generateAndStore(String dateKey, String language) async {
    final verse = await VerseWorker.instance.getTodaysVerse(language: language);
    final reference = verse['reference'] as String;

    String text;
    try {
      text = await GroqService.instance.chat([
        GroqMessage(
          role: 'system',
          content:
              'You write short, warm, biblically grounded daily prayers '
              '(4-6 sentences) for a Christian devotional app. Base the '
              'prayer thematically on the given verse reference without '
              'quoting long passages of scripture. Plain text only, no '
              'markdown, no preamble like "Here is a prayer".',
        ),
        GroqMessage(role: 'user', content: 'Write today\'s prayer based on $reference.'),
      ]);
    } catch (_) {
      text = 'Lord, as we reflect on $reference today, help us live it out '
          'in how we treat others, and give us peace for whatever this day '
          'holds. Amen.';
    }

    await _collection.doc(dateKey).set({
      'text': text,
      'based_on_reference': reference,
      'generated_at': FieldValue.serverTimestamp(),
      'source': 'client_v1',
    });

    await _cacheLocally(dateKey, text);
    return {'text': text, 'source': 'generated'};
  }

  Future<void> _cacheLocally(String dateKey, String text) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_cacheKey, text);
    await prefs.setString(_cacheDateKey, dateKey);
  }

  String _todayKey() {
    final now = DateTime.now();
    return '${now.year.toString().padLeft(4, '0')}-'
        '${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}';
  }
}
