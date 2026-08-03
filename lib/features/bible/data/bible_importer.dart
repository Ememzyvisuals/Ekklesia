import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:isar/isar.dart';

import 'bible_local_schema.dart';

/// Thrown for any import failure — malformed source, checksum mismatch, or
/// structurally incomplete data (missing books/chapters/verses). The
/// importer refuses to write partial/corrupt data rather than silently
/// importing an incomplete Bible.
class BibleImportException implements Exception {
  BibleImportException(this.message);
  final String message;
  @override
  String toString() => 'BibleImportException: $message';
}

class BibleImportResult {
  BibleImportResult({
    required this.language,
    required this.booksImported,
    required this.chaptersImported,
    required this.versesImported,
    required this.approximateVerses,
    required this.omittedVerses,
    required this.elapsed,
    required this.checksum,
  });

  final String language;
  final int booksImported;
  final int chaptersImported;
  final int versesImported;
  final int approximateVerses;
  final int omittedVerses;
  final Duration elapsed;
  final String checksum;
}

/// Imports one language's Bible dataset (assets/bible/<lang>.json, produced
/// by the offline build_bible.py pipeline from KJV JSON + read-aloud script
/// sources) into Isar.
///
/// Source data note: for yo/ha/ig/pcm, the original files ship without verse
/// numbers (they're read-aloud recording scripts) but with one verse per
/// line — build_bible.py reconstructs verse numbers from line position,
/// cross-checked against KJV's per-chapter verse count. ~99.7% of chapters
/// match exactly. See BIBLE_IMPORT_NOTES.md for the full anomaly list.
class BibleImporter {
  BibleImporter(this.isar);
  final Isar isar;

  static const _manifestAsset = 'assets/bible/manifest.json';

  Future<BibleImportResult> importLanguage(String language) async {
    final manifestRaw = await rootBundle.loadString(_manifestAsset);
    final manifest = json.decode(manifestRaw) as Map<String, dynamic>;
    final entry = manifest[language] as Map<String, dynamic>?;
    if (entry == null) {
      throw BibleImportException('No manifest entry for language "$language".');
    }

    final assetPath = entry['file'] as String;
    final expectedChecksum = entry['sha256'] as String;

    final bytes = await rootBundle.load(assetPath);
    final byteList = bytes.buffer.asUint8List();
    final actualChecksum = sha256.convert(byteList).toString();
    if (actualChecksum != expectedChecksum) {
      throw BibleImportException(
        'Checksum mismatch for "$language": expected $expectedChecksum, got $actualChecksum. '
        'Refusing to import — the bundled asset may be corrupt or out of date with manifest.json.',
      );
    }

    late Map<String, dynamic> data;
    try {
      data = json.decode(utf8.decode(byteList)) as Map<String, dynamic>;
    } catch (e) {
      throw BibleImportException('Malformed JSON for "$language": $e');
    }

    final books = data['books'] as List<dynamic>? ?? [];
    if (books.length != 66) {
      throw BibleImportException(
        'Expected 66 books for "$language", found ${books.length} — refusing partial import.',
      );
    }

    final sw = Stopwatch()..start();
    var bookCount = 0,
        chapterCount = 0,
        verseCount = 0,
        approxCount = 0,
        omittedCount = 0;

    await isar.writeTxn(() async {
      // Re-imports replace the previous copy of this language cleanly —
      // no duplicate rows if the user re-runs import.
      await isar.bibleBookEntitys
          .filter()
          .languageEqualTo(language)
          .deleteAll();
      await isar.bibleChapterEntitys
          .filter()
          .languageEqualTo(language)
          .deleteAll();
      await isar.bibleVerseEntitys
          .filter()
          .languageEqualTo(language)
          .deleteAll();

      for (final rawBook in books) {
        final book = rawBook as Map<String, dynamic>;
        final code = book['code'] as String;
        final chapters = book['chapters'] as List<dynamic>? ?? [];
        if (chapters.isEmpty) {
          throw BibleImportException(
              'Book $code has zero chapters in "$language" — aborting import.');
        }

        await isar.bibleBookEntitys.put(
          BibleBookEntity()
            ..language = language
            ..code = code
            ..name = book['name'] as String
            ..testament = book['testament'] as String
            ..position = book['position'] as int
            ..chapterCount = chapters.length,
        );
        bookCount++;

        for (final rawChapter in chapters) {
          final chapter = rawChapter as Map<String, dynamic>;
          final chapterNumber = chapter['number'] as int;
          final verses = chapter['verses'] as List<dynamic>? ?? [];
          if (verses.isEmpty) {
            throw BibleImportException(
              '$code chapter $chapterNumber has zero verses in "$language" — aborting import.',
            );
          }

          await isar.bibleChapterEntitys.put(
            BibleChapterEntity()
              ..language = language
              ..bookCode = code
              ..number = chapterNumber
              ..verseCount = verses.length
              ..localTitle = chapter['localTitle'] as String?,
          );
          chapterCount++;

          for (final rawVerse in verses) {
            final verse = rawVerse as Map<String, dynamic>;
            final text = verse['text'] as String?;
            final isOmitted = verse['omitted'] == true;
            final isApprox = verse['approximate'] == true;
            if (isOmitted) omittedCount++;
            if (isApprox) approxCount++;

            await isar.bibleVerseEntitys.put(
              BibleVerseEntity()
                ..language = language
                ..bookCode = code
                ..chapter = chapterNumber
                ..number = verse['number'] as int
                ..text = text
                ..omitted = isOmitted
                ..approximate = isApprox
                ..normalizedText = _normalize(text),
            );
            verseCount++;
          }
        }
      }

      await isar.bibleImportRecordEntitys.put(
        BibleImportRecordEntity()
          ..language = language
          ..checksum = actualChecksum
          ..booksImported = bookCount
          ..chaptersImported = chapterCount
          ..versesImported = verseCount
          ..approximateVerseCount = approxCount
          ..omittedVerseCount = omittedCount
          ..importedAt = DateTime.now(),
      );
    });

    sw.stop();
    return BibleImportResult(
      language: language,
      booksImported: bookCount,
      chaptersImported: chapterCount,
      versesImported: verseCount,
      approximateVerses: approxCount,
      omittedVerses: omittedCount,
      elapsed: sw.elapsed,
      checksum: actualChecksum,
    );
  }

  Future<bool> isImported(String language) async {
    final record = await isar.bibleImportRecordEntitys
        .filter()
        .languageEqualTo(language)
        .findFirst();
    return record != null && record.booksImported == 66;
  }

  static String _normalize(String? text) {
    if (text == null) return '';
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\p{L}\p{N}\s]', unicode: true), '');
  }
}
