/// A single YouTube video (uploaded message or live program) from DCLM's
/// channel, cached in Firestore per the addendum's cache strategy: title,
/// thumbnail, duration, publishedAt, videoId, description, channel,
/// liveStatus — nothing more, so the cache never accidentally holds a raw
/// API response with fields the UI doesn't use.
enum LiveStatus { none, live, upcoming }

class VideoEntry {
  const VideoEntry({
    required this.videoId,
    required this.title,
    required this.description,
    required this.thumbnailUrl,
    required this.publishedAt,
    required this.channelTitle,
    this.durationSeconds,
    this.liveStatus = LiveStatus.none,
    this.category,
  });

  final String videoId;
  final String title;
  final String description;
  final String thumbnailUrl;
  final DateTime publishedAt;
  final String channelTitle;

  /// Null for live/upcoming broadcasts (YouTube doesn't report a fixed
  /// duration for those until they end).
  final int? durationSeconds;
  final LiveStatus liveStatus;

  /// One of the Library categories (Sunday Service, Bible Study, Revival,
  /// GCK, Programs, Impact Academy, Special Messages) — assigned by title
  /// keyword matching in YoutubeRepository, since the YouTube API itself
  /// has no concept of these categories. Null until categorized.
  final String? category;

  String get watchUrl => 'https://www.youtube.com/watch?v=$videoId';

  factory VideoEntry.fromFirestore(Map<String, dynamic> data) => VideoEntry(
        videoId: data['video_id'] as String,
        title: data['title'] as String? ?? 'Untitled',
        description: data['description'] as String? ?? '',
        thumbnailUrl: data['thumbnail_url'] as String? ?? '',
        publishedAt: (data['published_at'] is String)
            ? DateTime.tryParse(data['published_at'] as String) ?? DateTime.now()
            : DateTime.now(),
        channelTitle: data['channel'] as String? ?? 'DCLM',
        durationSeconds: data['duration_seconds'] as int?,
        liveStatus: LiveStatus.values.firstWhere(
          (s) => s.name == (data['live_status'] as String? ?? 'none'),
          orElse: () => LiveStatus.none,
        ),
        category: data['category'] as String?,
      );

  Map<String, dynamic> toFirestore() => {
        'video_id': videoId,
        'title': title,
        'description': description,
        'thumbnail_url': thumbnailUrl,
        'published_at': publishedAt.toIso8601String(),
        'channel': channelTitle,
        'duration_seconds': durationSeconds,
        'live_status': liveStatus.name,
        'category': category,
      };
}
