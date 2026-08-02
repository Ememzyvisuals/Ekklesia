import 'package:isar/isar.dart';

part 'bible_annotations_schema.g.dart';

/// One row per highlighted verse. Re-highlighting the same verse with a
/// different color replaces the row (see BibleAnnotationsRepository) rather
/// than stacking duplicates — a verse has at most one highlight color.
@collection
class BibleHighlightEntity {
  Id id = Isar.autoIncrement;

  @Index(composite: [
    CompositeIndex('bookCode'),
    CompositeIndex('chapter'),
    CompositeIndex('verseNumber'),
  ])
  late String language;

  late String bookCode;
  late int chapter;
  late int verseNumber;

  /// ARGB hex string, e.g. 'FFFFEB3B' for yellow — matches
  /// Color(int.parse(hex, radix: 16)).
  late String colorHex;
  late DateTime createdAt;
}

/// One row per verse note. A verse has at most one note (editing replaces
/// it) — this isn't a comment thread, it's "my note on this verse."
@collection
class BibleNoteEntity {
  Id id = Isar.autoIncrement;

  @Index(composite: [
    CompositeIndex('bookCode'),
    CompositeIndex('chapter'),
    CompositeIndex('verseNumber'),
  ])
  late String language;

  late String bookCode;
  late int chapter;
  late int verseNumber;
  late String text;
  late DateTime updatedAt;
}

/// Last-read position per Bible language — one row per language, replaced
/// on every chapter open. Powers "Continue Reading."
@collection
class BibleReadingProgressEntity {
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String language;

  late String bookCode;
  late String bookName;
  late int chapter;
  late DateTime updatedAt;
}

/// Single global row tracking the reading streak across all Bible
/// languages/chapters combined — reading any chapter in any language
/// counts toward the same streak, per the spec's "Daily Reading, Streak"
/// requirement being about the habit, not per-translation.
@collection
class BibleReadingStreakEntity {
  Id id = Isar.autoIncrement;

  int currentStreak = 0;
  int longestStreak = 0;
  int totalDaysRead = 0;

  /// Calendar day number (days since epoch, local time) of the last day
  /// any chapter was read — used to detect "still today" vs "yesterday,
  /// streak continues" vs "gap, streak resets."
  int lastReadDay = 0;
}
