import 'package:go_router/go_router.dart';
import 'package:flutter/foundation.dart';

import '../services/auth_service.dart';
import '../../features/onboarding/presentation/onboarding_screen.dart';
import '../../features/auth/presentation/login_screen.dart';
import '../../features/auth/presentation/signup_screen.dart';
import '../../features/home/presentation/home_screen.dart';
import '../../features/home/presentation/live_screen.dart';
import '../../features/bible/presentation/bible_screen.dart';
import '../../features/learn/presentation/learn_screen.dart';
import '../../features/ai/presentation/ai_assistant_screen.dart';
import '../../features/settings/presentation/settings_screen.dart';
import '../../features/games/presentation/games_screen.dart';
import '../../features/profile/presentation/profile_screen.dart';
import '../../features/sermons/presentation/sermon_library_screen.dart';
import '../../features/downloads/presentation/downloads_screen.dart';
import '../../features/notifications/presentation/notifications_screen.dart';
import '../../features/bookmarks/presentation/bookmarks_screen.dart';
import '../../features/search/presentation/search_screen.dart';

/// Notifies GoRouter to re-evaluate [redirect] whenever Firebase auth
/// state changes (sign in / sign out), so navigation reacts immediately
/// without manual context.go calls scattered through login/signup.
class _AuthRefreshNotifier extends ChangeNotifier {
  _AuthRefreshNotifier() {
    AuthService.instance.authStateChanges.listen((_) => notifyListeners());
  }
}

final _authRefreshNotifier = _AuthRefreshNotifier();

/// Gateway logic:
///   1. If onboarding hasn't been completed -> /onboarding
///   2. Else if not signed in -> /login (or /signup, both allowed through)
///   3. Else -> allow into the main app
///
/// [onboardingSeen] is checked synchronously via a cached flag set by
/// main.dart at startup (see main.dart) to avoid an async redirect race.
bool onboardingSeenCache = false;

final GoRouter appRouter = GoRouter(
  initialLocation: '/onboarding',
  refreshListenable: _authRefreshNotifier,
  redirect: (context, state) {
    final loggedIn = AuthService.instance.isSignedIn;
    final goingToAuth =
        state.matchedLocation == '/login' || state.matchedLocation == '/signup';
    final goingToOnboarding = state.matchedLocation == '/onboarding';

    if (!onboardingSeenCache && !goingToOnboarding) return '/onboarding';
    if (onboardingSeenCache && goingToOnboarding)
      return loggedIn ? '/home' : '/login';
    if (!loggedIn && !goingToAuth && !goingToOnboarding) return '/login';
    if (loggedIn && goingToAuth) return '/home';
    return null;
  },
  routes: [
    GoRoute(
        path: '/onboarding',
        builder: (context, state) => const OnboardingScreen()),
    GoRoute(path: '/login', builder: (context, state) => const LoginScreen()),
    GoRoute(path: '/signup', builder: (context, state) => const SignupScreen()),
    GoRoute(path: '/home', builder: (context, state) => const HomeScreen()),
    GoRoute(path: '/live', builder: (context, state) => const LiveScreen()),
    GoRoute(path: '/bible', builder: (context, state) => const BibleScreen()),
    GoRoute(path: '/learn', builder: (context, state) => const LearnScreen()),
    GoRoute(
        path: '/ai', builder: (context, state) => const AiAssistantScreen()),
    GoRoute(
        path: '/settings', builder: (context, state) => const SettingsScreen()),
    GoRoute(path: '/games', builder: (context, state) => const GamesScreen()),
    GoRoute(
        path: '/profile', builder: (context, state) => const ProfileScreen()),
    GoRoute(
        path: '/sermons',
        builder: (context, state) => const SermonLibraryScreen()),
    GoRoute(
        path: '/downloads',
        builder: (context, state) => const DownloadsScreen()),
    GoRoute(
        path: '/notifications',
        builder: (context, state) => const NotificationsScreen()),
    GoRoute(
        path: '/bookmarks',
        builder: (context, state) => const BookmarksScreen()),
    GoRoute(path: '/search', builder: (context, state) => const SearchScreen()),
  ],
);
