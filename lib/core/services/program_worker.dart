import 'package:cloud_firestore/cloud_firestore.dart';

import '../config/app_config.dart';
import '../shared/result.dart';
import '../../features/sermons/data/youtube_repository.dart';
import '../../features/sermons/domain/video_entry.dart';

/// A single row in `programs` — a recurring church schedule rule (e.g.
/// "Sunday Service, Sundays, 09:00"), NOT a specific dated event. Per the
/// spec's "never require an administrator to pin programs" rule, these
/// rules exist so ProgramWorker can compute today's schedule automatically
/// instead of someone manually creating a dated entry every week.
///
/// Seeded manually today (no admin panel per spec — "Do NOT build an
/// in-app admin panel"); a future Cloud Function could manage this
/// collection instead of a human, without any client-side change.
class ProgramRule {
  const ProgramRule({
    required this.title,
    required this.dayOfWeek, // 1 = Monday .. 7 = Sunday (DateTime.weekday)
    required this.startHour,
    required this.startMinute,
    required this.category,
  });

  final String title;
  final int dayOfWeek;
  final int startHour;
  final int startMinute;
  final String category;

  factory ProgramRule.fromFirestore(Map<String, dynamic> data) => ProgramRule(
        title: data['title'] as String? ?? 'Program',
        dayOfWeek: data['day_of_week'] as int? ?? 7,
        startHour: data['start_hour'] as int? ?? 9,
        startMinute: data['start_minute'] as int? ?? 0,
        category: data['category'] as String? ?? 'Programs',
      );
}

/// Combined view the Home screen needs: what's live right now, what's
/// coming up, what was recently uploaded, and today's schedule — computed
/// automatically from YouTube state + the `programs` schedule rules, never
/// from a manually-pinned "featured" flag.
class ProgramSnapshot {
  const ProgramSnapshot({
    this.live,
    this.upcoming,
    this.recent,
    required this.todaysSchedule,
  });

  final VideoEntry? live;
  final VideoEntry? upcoming;
  final VideoEntry? recent;
  final List<ProgramRule> todaysSchedule;

  /// Featured = live if there is one, else the next scheduled/upcoming
  /// item, else the most recent upload. Never a manually-set flag.
  VideoEntry? get featured => live ?? upcoming ?? recent;
}

class ProgramWorker {
  ProgramWorker._internal();
  static final ProgramWorker instance = ProgramWorker._internal();

  final _firestore = FirebaseFirestore.instance;
  final _youtubeRepository = YoutubeRepository();

  Future<ProgramSnapshot> getSnapshot() async {
    VideoEntry? live;
    VideoEntry? upcoming;
    VideoEntry? recent;

    // config/youtube_live_status is a single doc (see YoutubeRepository) —
    // read it directly rather than subscribing to the stream, since this
    // is a one-shot snapshot for Home, not a live-updating widget.
    final liveDoc = await _firestore
        .collection('config')
        .doc(AppConfig.youtubeLiveStatusDoc)
        .get();
    if (liveDoc.exists && liveDoc.data()?['video_id'] != null) {
      final entry = VideoEntry.fromFirestore(liveDoc.data()!);
      if (entry.liveStatus == LiveStatus.live) {
        live = entry;
      } else if (entry.liveStatus == LiveStatus.upcoming) {
        upcoming = entry;
      }
    }

    final cachedResult = await _youtubeRepository.getCachedUploads();
    if (cachedResult is ResultSuccess<List<VideoEntry>> &&
        cachedResult.data.isNotEmpty) {
      recent = cachedResult.data.first;
    }

    final todaysSchedule = await _todaysScheduleRules();

    return ProgramSnapshot(
      live: live,
      upcoming: upcoming,
      recent: recent,
      todaysSchedule: todaysSchedule,
    );
  }

  Future<List<ProgramRule>> _todaysScheduleRules() async {
    final weekday = DateTime.now().weekday;
    final snapshot = await _firestore
        .collection(AppConfig.programsCollection)
        .where('day_of_week', isEqualTo: weekday)
        .get();
    final rules =
        snapshot.docs.map((d) => ProgramRule.fromFirestore(d.data())).toList();
    rules.sort((a, b) => (a.startHour * 60 + a.startMinute)
        .compareTo(b.startHour * 60 + b.startMinute));
    return rules;
  }
}
