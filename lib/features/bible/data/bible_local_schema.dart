import 'package:isar/isar.dart';

part 'bible_local_schema.g.dart';

/// One row per (language, book). [language] is one of AppConfig's bible
/// language codes: 'en', 'yo', 'ha', 'ig', 'pcm'. [code] is the canonical
/// 3-letter book code from bible_books.dart (e.g. 'GEN'), shared across all
/// languages so cross-language lookups (e.g. switching translation mid-read)
/// stay on the same book/chapter/verse.
@collection
class BibleBookEntity {
  Id id = Isar.autoIncrement;

  @Index(composite: [CompositeIndex('code')])
  late String language;

  late String code;
  late String name; // display name — local-language title for this book
  late String testament; // 'OT' or 'NT'
  late int position; // 1..66
  late int chapterCount;
}

/// One row per (language, book, chapter).
@collection
class BibleChapterEntity {
  Id id = Isar.autoIncrement;

  @Index(composite: [CompositeIndex('bookCode'), CompositeIndex('number')])
  late String language;

  late String bookCode;
  late int number;
  late int verseCount;
  String? localTitle;
}

/// One row per (language, book, chapter, verse).
///
/// [omitted] = true means this verse number exists in standard versification
/// but this translation doesn't include it (a small, well-documented set of
/// textual-tradition differences — see BibleImporter's KNOWN_OMISSIONS).
/// [approximate] = true means the source restructured this chapter (merged
/// or split verses) and the verse number here is a best-effort sequential
/// position rather than a verified standard verse number — see
/// BIBLE_IMPORT_NOTES.md for the exact list of affected chapters.
@collection
class BibleVerseEntity {
  Id id = Isar.autoIncrement;

  @Index(composite: [
    CompositeIndex('bookCode'),
    CompositeIndex('chapter'),
    CompositeIndex('number'),
  ])
  late String language;

  late String bookCode;
  late int chapter;
  late int number;
  String? text;
  bool omitted = false;
  bool approximate = false;

  @Index(caseSensitive: false, type: IndexType.value)
  String normalizedText = '';
}

/// Tracks which languages have been imported and with what result, so the
/// UI can show "Download/Import" vs "Ready offline" without re-scanning
/// every verse row on every app open.
@collection
class BibleImportRecordEntity {
  Id id = Isar.autoIncrement;

  @Index(unique: true, replace: true)
  late String language;

  late String checksum;
  late int booksImported;
  late int chaptersImported;
  late int versesImported;
  late int approximateVerseCount;
  late int omittedVerseCount;
  late DateTime importedAt;
}
