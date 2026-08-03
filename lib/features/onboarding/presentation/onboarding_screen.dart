import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/config/app_theme.dart';
import '../../../core/services/app_settings_service.dart';

const _onboardingSeenKey = 'onboarding_seen';

Future<bool> hasSeenOnboarding() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_onboardingSeenKey) ?? false;
}

/// First-run flow: welcome + a language choice (drives default TTS/Bible
/// language across the app via [languageProvider]). Shown once; skipped
/// on subsequent launches via the SharedPreferences flag above, checked
/// by the router's redirect logic.
class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pageController = PageController();
  int _page = 0;
  String _selectedLanguage = 'english';

  static const _languages = [
    ('english', 'English'),
    ('yoruba', 'Yorùbá'),
    ('hausa', 'Hausa'),
    ('igbo', 'Igbo'),
    ('pidgin', 'Pidgin'),
  ];

  Future<void> _finish() async {
    await ref.read(languageProvider.notifier).setLanguage(_selectedLanguage);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingSeenKey, true);
    if (mounted) context.go('/login');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (i) => setState(() => _page = i),
                children: [
                  _WelcomePage(
                    title: 'Welcome to Ekklesia',
                    subtitle: 'Sermons, Bible study, and an AI companion for '
                        'DCLM members and Christians everywhere — in your '
                        'own language.',
                    icon: Icons.church,
                  ),
                  _WelcomePage(
                    title: 'Listen Anywhere',
                    subtitle: 'DCLM radio and messages keep playing even '
                        'when your screen locks.',
                    icon: Icons.radio,
                  ),
                  _LanguagePage(
                    selected: _selectedLanguage,
                    languages: _languages,
                    onSelect: (code) =>
                        setState(() => _selectedLanguage = code),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: Row(
                children: [
                  Row(
                    children: List.generate(
                        3,
                        (i) => Container(
                              margin: const EdgeInsets.only(right: 6),
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: i == _page
                                    ? AppColors.primary
                                    : AppColors.primary.withValues(alpha: 0.2),
                              ),
                            )),
                  ),
                  const Spacer(),
                  ElevatedButton(
                    onPressed: () {
                      if (_page < 2) {
                        _pageController.nextPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                        );
                      } else {
                        _finish();
                      }
                    },
                    child: Text(_page < 2 ? 'Next' : 'Get Started'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WelcomePage extends StatelessWidget {
  const _WelcomePage(
      {required this.title, required this.subtitle, required this.icon});
  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 96, color: AppColors.primary),
          const SizedBox(height: 32),
          Text(title,
              style: Theme.of(context).textTheme.headlineMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          Text(subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary(context))),
        ],
      ),
    );
  }
}

class _LanguagePage extends StatelessWidget {
  const _LanguagePage(
      {required this.selected,
      required this.languages,
      required this.onSelect});
  final String selected;
  final List<(String, String)> languages;
  final void Function(String) onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Choose your language',
              style: Theme.of(context).textTheme.headlineMedium,
              textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text('You can change this anytime in Settings',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary(context))),
          const SizedBox(height: 24),
          ...languages.map((l) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: InkWell(
                  onTap: () => onSelect(l.$1),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: selected == l.$1
                          ? AppColors.primary.withValues(alpha: 0.1)
                          : AppTheme.surface(context),
                      border: Border.all(
                          color: selected == l.$1
                              ? AppColors.primary
                              : Colors.transparent,
                          width: 2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Text(l.$2,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        const Spacer(),
                        if (selected == l.$1)
                          const Icon(Icons.check_circle,
                              color: AppColors.primary),
                      ],
                    ),
                  ),
                ),
              )),
        ],
      ),
    );
  }
}
