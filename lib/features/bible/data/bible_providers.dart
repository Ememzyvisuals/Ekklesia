import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:isar/isar.dart';

import '../../../core/services/isar_service.dart';
import 'bible_annotations_repository.dart';
import 'bible_audio_cache.dart';
import 'bible_importer.dart';
import 'bible_local_schema.dart';
import 'bible_repository.dart';

/// Isar must already be open (IsarService.instance.open() awaited in
/// main()) by the time any widget reads this provider.
final isarProvider = Provider<Isar>((ref) => IsarService.instance.isar);

final bibleRepositoryProvider = Provider<BibleRepository>((ref) {
  return BibleRepository(ref.watch(isarProvider));
});

final bibleImporterProvider = Provider<BibleImporter>((ref) {
  return BibleImporter(ref.watch(isarProvider));
});

final bibleAudioCacheProvider = Provider<BibleAudioCache>((ref) {
  return BibleAudioCache(ref.watch(isarProvider));
});

final bibleAnnotationsRepositoryProvider = Provider<BibleAnnotationsRepository>((ref) {
  return BibleAnnotationsRepository(ref.watch(isarProvider));
});

/// Bible dataset language codes ('en'/'yo'/'ha'/'ig'/'pcm') mapped from the
/// app's internal language keys used elsewhere (LanguageNotifier,
/// EkklesiaLanguage) — see AppConfig/app_settings_service.dart.
const Map<String, String> kAppLanguageToBibleCode = {
  'english': 'en',
  'yoruba': 'yo',
  'hausa': 'ha',
  'igbo': 'ig',
  'pidgin': 'pcm',
};

const Map<String, String> kBibleCodeLabel = {
  'en': 'English',
  'yo': 'Yoruba',
  'ha': 'Hausa',
  'ig': 'Igbo',
  'pcm': 'Nigerian Pidgin',
};

/// Which Bible language is currently selected for reading (independent of
/// the app's UI language — a Hausa-UI user can still read the English
/// Bible, and vice versa).
final bibleLanguageProvider = StateProvider<String>((ref) => 'en');

/// Re-checked whenever [bibleLanguageProvider] changes or invalidated after
/// an import completes.
final bibleImportStatusProvider = FutureProvider.autoDispose.family<bool, String>((ref, language) async {
  final repo = ref.watch(bibleRepositoryProvider);
  return repo.isLanguageImported(language);
});
