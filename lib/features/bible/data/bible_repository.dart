import 'package:isar/isar.dart';

import '../domain/bible_books.dart';
import 'bible_local_schema.dart';

/// Thrown when a "Book Chapter:Verse"-style reference can't be parsed or
/// doesn't resolve to an imported book/chapter/verse.
class BibleReferenceException implements Exception {
  BibleReferenceException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ParsedReference {
  ParsedReference({required this.book, required this.chapter, this.startVerse, this.endVerse});
  final CanonicalBook book;
  final int chapter;
  final int? startVerse;
  final int? endVerse;
}

/// Parses "John 3:16", "John 3:16-18", "1 Samuel 17", "Psalms 23:1" into a
/// [ParsedReference]. Pure text parsing — no I/O, no dependency on which
/// languages are imported.
ParsedReference parseBibleReference(String raw) {
  final input = raw.trim();
  final match = RegExp(r'^(.+?)\s+(\d+)(?::(\d+)(?:-(\d+))?)?$').firstMatch(input);
  if (match == null) {
    throw BibleReferenceException('Could not parse reference "$raw". Try "John 3:16" or "Psalms 23".');
  }
  final bookName = match.group(1)!;
  final chapter = int.parse(match.group(2)!);
  final startVerse = match.group(3) != null ? int.parse(match.group(3)!) : null;
  final endVerse = match.group(4) != null ? int.parse(match.group(4)!) : startVerse;

  final book = findCanonicalBookByName(bookName);
  if (book == null) {
    throw BibleReferenceException('Unknown book "$bookName" in reference "$raw".');
  }
  return ParsedReference(book: book, chapter: chapter, startVerse: startVerse, endVerse: endVerse);
}

class BibleRepository {
  BibleRepository(this.isar);
  final Isar isar;

  Future<List<BibleBookEntity>> getBooks(String language) {
    return isar.bibleBookEntitys.filter().languageEqualTo(language).sortByPosition().findAll();
  }

  Future<BibleChapterEntity?> getChapter(String language, String bookCode, int chapterNumber) {
    return isar.bibleChapterEntitys
        .filter()
        .languageEqualTo(language)
        .bookCodeEqualTo(bookCode)
        .numberEqualTo(chapterNumber)
        .findFirst();
  }

  Future<List<BibleVerseEntity>> getVerses(
    String language,
    String bookCode,
    int chapterNumber, {
    int? startVerse,
    int? endVerse,
  }) {
    var q = isar.bibleVerseEntitys
        .filter()
        .languageEqualTo(language)
        .bookCodeEqualTo(bookCode)
        .chapterEqualTo(chapterNumber);
    if (startVerse != null) {
      q = q.and().numberBetween(startVerse, endVerse ?? startVerse);
    }
    return q.sortByNumber().findAll();
  }

  /// Resolves a "Book Chapter:Verse[-Verse]" reference to verse rows for
  /// [language]. Throws [BibleReferenceException] if unparseable, or if the
  /// language hasn't been imported / the reference is out of range.
  Future<List<BibleVerseEntity>> getPassage(String reference, {required String language}) async {
    final parsed = parseBibleReference(reference);
    final verses = await getVerses(
      language,
      parsed.book.code,
      parsed.chapter,
      startVerse: parsed.startVerse,
      endVerse: parsed.endVerse,
    );
    if (verses.isEmpty) {
      throw BibleReferenceException(
        '"$reference" not found in language "$language" — is this language imported, '
        'and does ${parsed.book.englishName} ${parsed.chapter} exist?',
      );
    }
    return verses;
  }

  /// Full-text substring search over normalized verse text. Offline, no API.
  Future<List<BibleVerseEntity>> search(String language, String query, {int limit = 50}) {
    final normalized = query
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), '')
        .trim();
    if (normalized.isEmpty) return Future.value([]);
    return isar.bibleVerseEntitys
        .filter()
        .languageEqualTo(language)
        .normalizedTextContains(normalized)
        .limit(limit)
        .findAll();
  }

  Future<bool> isLanguageImported(String language) async {
    final count = await isar.bibleBookEntitys.filter().languageEqualTo(language).count();
    return count >= 66;
  }

  Future<BibleImportRecordEntity?> importRecord(String language) {
    return isar.bibleImportRecordEntitys.filter().languageEqualTo(language).findFirst();
  }
}
