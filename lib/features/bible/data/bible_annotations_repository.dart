import 'package:isar/isar.dart';

import 'bible_annotations_schema.dart';

class BibleAnnotationsRepository {
  BibleAnnotationsRepository(this.isar);
  final Isar isar;

  // ---- Highlights ----

  Future<Map<int, BibleHighlightEntity>> getHighlightsForChapter(
    String language,
    String bookCode,
    int chapter,
  ) async {
    final rows = await isar.bibleHighlightEntitys
        .filter()
        .languageEqualTo(language)
        .bookCodeEqualTo(bookCode)
        .chapterEqualTo(chapter)
        .findAll();
    return {for (final r in rows) r.verseNumber: r};
  }

  Future<void> setHighlight({
    required String language,
    required String bookCode,
    required int chapter,
    required int verseNumber,
    required String colorHex,
  }) async {
    final existing = await isar.bibleHighlightEntitys
        .filter()
        .languageEqualTo(language)
        .bookCodeEqualTo(bookCode)
        .chapterEqualTo(chapter)
        .verseNumberEqualTo(verseNumber)
        .findFirst();
    await isar.writeTxn(() async {
      if (existing != null) await isar.bibleHighlightEntitys.delete(existing.id);
      await isar.bibleHighlightEntitys.put(
        BibleHighlightEntity()
          ..language = language
          ..bookCode = bookCode
          ..chapter = chapter
          ..verseNumber = verseNumber
          ..colorHex = colorHex
          ..createdAt = DateTime.now(),
      );
    });
  }

  Future<void> removeHighlight({
    required String language,
    required String bookCode,
    required int chapter,
    required int verseNumber,
  }) async {
    final existing = await isar.bibleHighlightEntitys
        .filter()
        .languageEqualTo(language)
        .bookCodeEqualTo(bookCode)
        .chapterEqualTo(chapter)
        .verseNumberEqualTo(verseNumber)
        .findFirst();
    if (existing == null) return;
    await isar.writeTxn(() => isar.bibleHighlightEntitys.delete(existing.id));
  }

  // ---- Notes ----

  Future<BibleNoteEntity?> getNote({
    required String language,
    required String bookCode,
    required int chapter,
    required int verseNumber,
  }) {
    return isar.bibleNoteEntitys
        .filter()
        .languageEqualTo(language)
        .bookCodeEqualTo(bookCode)
        .chapterEqualTo(chapter)
        .verseNumberEqualTo(verseNumber)
        .findFirst();
  }

  Future<void> setNote({
    required String language,
    required String bookCode,
    required int chapter,
    required int verseNumber,
    required String text,
  }) async {
    final existing = await getNote(
      language: language, bookCode: bookCode, chapter: chapter, verseNumber: verseNumber,
    );
    await isar.writeTxn(() async {
      if (existing != null) await isar.bibleNoteEntitys.delete(existing.id);
      if (text.trim().isEmpty) return; // empty text = delete, don't store a blank note
      await isar.bibleNoteEntitys.put(
        BibleNoteEntity()
          ..language = language
          ..bookCode = bookCode
          ..chapter = chapter
          ..verseNumber = verseNumber
          ..text = text.trim()
          ..updatedAt = DateTime.now(),
      );
    });
  }

  // ---- Reading progress / Continue Reading ----

  Future<BibleReadingProgressEntity?> getProgress(String language) {
    return isar.bibleReadingProgressEntitys.filter().languageEqualTo(language).findFirst();
  }

  Future<void> saveProgress({
    required String language,
    required String bookCode,
    required String bookName,
    required int chapter,
  }) async {
    await isar.writeTxn(() async {
      await isar.bibleReadingProgressEntitys.put(
        BibleReadingProgressEntity()
          ..language = language
          ..bookCode = bookCode
          ..bookName = bookName
          ..chapter = chapter
          ..updatedAt = DateTime.now(),
      );
    });
  }

  // ---- Reading streak ----

  static int _dayNumber(DateTime dt) => DateTime(dt.year, dt.month, dt.day).difference(DateTime(1970)).inDays;

  Future<BibleReadingStreakEntity> getStreak() async {
    final existing = await isar.bibleReadingStreakEntitys.where().findFirst();
    return existing ?? BibleReadingStreakEntity();
  }

  /// Call once whenever a chapter is opened (any language). No-ops if
  /// today has already been recorded — reading five chapters in one day
  /// only counts as one streak day, same as any habit tracker.
  Future<BibleReadingStreakEntity> recordReadingActivity() async {
    final today = _dayNumber(DateTime.now());
    var streak = await isar.bibleReadingStreakEntitys.where().findFirst();

    if (streak != null && streak.lastReadDay == today) {
      return streak; // already recorded today — no change
    }

    final wasConsecutive = streak != null && streak.lastReadDay == today - 1;
    final updated = (streak ?? BibleReadingStreakEntity())
      ..currentStreak = wasConsecutive ? (streak!.currentStreak + 1) : 1
      ..totalDaysRead = (streak?.totalDaysRead ?? 0) + 1
      ..lastReadDay = today;
    updated.longestStreak = updated.currentStreak > updated.longestStreak
        ? updated.currentStreak
        : updated.longestStreak;

    await isar.writeTxn(() => isar.bibleReadingStreakEntitys.put(updated));
    return updated;
  }
}
