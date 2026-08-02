import 'package:isar/isar.dart';
import 'package:path_provider/path_provider.dart';

import '../../features/bible/data/bible_annotations_schema.dart';
import '../../features/bible/data/bible_audio_cache_schema.dart';
import '../../features/bible/data/bible_local_schema.dart';

/// Opens and owns the single shared Isar instance for the app.
///
/// `isar` was already in pubspec.yaml but nothing in the repository actually
/// opened it — DownloadRepository deliberately used SharedPreferences
/// instead (see its doc comment). The offline Bible engine is the first
/// feature that needs real structured local storage at scale (five
/// languages x 66 books x ~31k verses each), so this is where Isar gets
/// wired up for real. Other features (Downloads, Bookmarks, etc.) can
/// migrate to Isar collections later using this same shared instance
/// instead of opening their own.
class IsarService {
  IsarService._internal();
  static final IsarService instance = IsarService._internal();

  Isar? _isar;

  /// Must be awaited once in main() before runApp(). Safe to call more than
  /// once (idempotent) — Isar.open with the same schema/name is a no-op if
  /// already open in this isolate.
  Future<Isar> open() async {
    if (_isar != null) return _isar!;
    final dir = await getApplicationDocumentsDirectory();
    _isar = await Isar.open(
      [
        BibleBookEntitySchema,
        BibleChapterEntitySchema,
        BibleVerseEntitySchema,
        BibleImportRecordEntitySchema,
        BibleAudioCacheEntitySchema,
        BibleHighlightEntitySchema,
        BibleNoteEntitySchema,
        BibleReadingProgressEntitySchema,
        BibleReadingStreakEntitySchema,
      ],
      directory: dir.path,
      name: 'ekklesia',
    );
    return _isar!;
  }

  /// Throws if [open] hasn't completed yet — call sites should only run
  /// after main()'s startup sequence.
  Isar get isar {
    final instance = _isar;
    if (instance == null) {
      throw StateError('IsarService.open() must be awaited in main() before use.');
    }
    return instance;
  }
}
