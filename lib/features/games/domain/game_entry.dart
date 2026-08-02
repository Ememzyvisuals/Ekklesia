/// One curated entry in the Games catalog. Populated manually in Firestore's
/// `games` collection — there is no automated source, because no free,
/// legitimately-licensed "biblical games API" exists (verified: trivia APIs
/// are either general-knowledge/non-Bible, or CC-BY-NC non-commercial only;
/// Bible-specific HTML5 games are one-time-purchase files, not APIs). Adding
/// a game means adding a Firestore document with a launch or embed URL that
/// the publisher has actually granted permission for — never scraped.
class GameEntry {
  const GameEntry({
    required this.id,
    required this.title,
    required this.description,
    required this.thumbnailUrl,
    required this.category,
    required this.ageRating,
    required this.developer,
    this.launchUrl,
    this.embedUrl,
  });

  final String id;
  final String title;
  final String description;
  final String thumbnailUrl;
  final String category;
  final String ageRating;
  final String developer;

  /// Set when the publisher has NOT granted in-app embedding — opens in the
  /// device's external browser instead.
  final String? launchUrl;

  /// Set only when the publisher has explicitly granted embedding
  /// permission — opens inside the app's WebView.
  final String? embedUrl;

  bool get isEmbeddable => embedUrl != null && embedUrl!.isNotEmpty;

  factory GameEntry.fromFirestore(String id, Map<String, dynamic> data) {
    return GameEntry(
      id: id,
      title: data['title'] as String? ?? 'Untitled',
      description: data['description'] as String? ?? '',
      thumbnailUrl: data['thumbnailUrl'] as String? ?? '',
      category: data['category'] as String? ?? 'General',
      ageRating: data['ageRating'] as String? ?? 'All ages',
      developer: data['developer'] as String? ?? 'Unknown',
      launchUrl: data['launchUrl'] as String?,
      embedUrl: data['embedUrl'] as String?,
    );
  }
}
