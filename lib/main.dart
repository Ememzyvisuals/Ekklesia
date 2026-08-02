import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'core/config/app_theme.dart';
import 'core/config/app_router.dart';
import 'l10n/generated/app_localizations.dart';
import 'core/services/app_settings_service.dart';
import 'core/services/sync_worker.dart';
import 'core/services/ai_config.dart';
import 'core/services/auth_service.dart';
import 'core/services/conversation_worker.dart';
import 'core/services/cleanup_worker.dart';
import 'core/services/notification_service.dart';
import 'core/services/isar_service.dart';
import 'features/sermons/data/youtube_worker.dart';
import 'features/onboarding/presentation/onboarding_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Loads .env (Groq key, YouTube key/channel). Copy .env.example to .env
  // and fill in your real keys before running.
  await dotenv.load(fileName: '.env');

  // Enables lock-screen / notification-shade playback controls for radio
  // and sermon audio — this is the reliability feature the official DCLM
  // app doesn't have.
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.ememzyvisuals.ekklesia.audio',
    androidNotificationChannelName: 'Ekklesia Audio',
    androidNotificationOngoing: true,
  );

  // NOTE: run `flutterfire configure` before first real run — this
  // needs firebase_options.dart, generated per-project, not included
  // here since it's tied to your actual Firebase project.
  await Firebase.initializeApp();

  // Opens the shared Isar database (offline Bible engine — Book/Chapter/
  // Verse collections). Must complete before any widget reads
  // isarProvider/bibleRepositoryProvider. Requires build_runner to have
  // generated bible_local_schema.g.dart first (see BIBLE_IMPORT_NOTES.md).
  await IsarService.instance.open();

  // Cache the onboarding-seen flag synchronously for the router's
  // redirect logic (which can't await inside GoRouter's redirect callback
  // without extra plumbing) — read once here before the app builds.
  onboardingSeenCache = await hasSeenOnboarding();

  SyncWorker.instance.start();

  // Resolves the live Groq model (primary vs fallback) once before any
  // chat UI is shown — see ai_config.dart. Safe to await here since it
  // fails open (keeps the configured default) rather than blocking on a
  // slow/failed network call.
  await AIConfig.instance.verify();

  // Foreground-interval refresh of the sermon/live-program cache — see
  // youtube_worker.dart's doc comment for why this isn't a true OS-level
  // background worker yet.
  YoutubeWorker().start();

  // Flushes any AI chat turns queued locally while offline, and starts
  // listening for connectivity to flush new ones as they're recorded via
  // ConversationWorker.instance.record(...) (see ai_assistant_screen.dart).
  // Uid-agnostic at startup — queued messages already carry their own uid.
  ConversationWorker.instance.start();

  // CleanupWorker/NotificationWorker need a signed-in uid, which isn't
  // available yet at this point for a fresh install (onboarding runs
  // first). Run cleanup once per sign-in instead of on a timer here —
  // cheap, idempotent, and doesn't need a second background scheduler.
  //
  // NotificationService.initialize was defined (FCM permission request +
  // token save + foreground message recording) but nothing in the app
  // actually called it — found while wiring this up, not a new gap this
  // introduces. Without it, users were never prompted for notification
  // permission and no fcm_token was ever saved to their user doc, so
  // every push notification the spec calls for would have silently gone
  // nowhere.
  AuthService.instance.authStateChanges.listen((user) {
    if (user != null) {
      CleanupWorker.instance.runOnce(uid: user.uid);
      NotificationService.instance.initialize(uid: user.uid);
    }
  });

  runApp(const ProviderScope(child: EkklesiaApp()));
}

class EkklesiaApp extends ConsumerWidget {
  const EkklesiaApp({super.key});

  /// Maps LanguageNotifier's app-internal language keys (also used by
  /// EkklesiaLanguage.code for TTS/Bible) to actual Locale codes. Nigerian
  /// Pidgin's ISO 639-3 code is `pcm` — not a typo, that's the real code
  /// (there's no ISO 639-1 two-letter code for Pidgin).
  Locale _localeFor(String languageKey) {
    switch (languageKey) {
      case 'yoruba':
        return const Locale('yo');
      case 'hausa':
        return const Locale('ha');
      case 'igbo':
        return const Locale('ig');
      case 'pidgin':
        return const Locale('pcm');
      case 'english':
      default:
        return const Locale('en');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final language = ref.watch(languageProvider);

    return MaterialApp.router(
      title: 'Ekklesia',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      routerConfig: appRouter,
      locale: _localeFor(language),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
    );
  }
}
