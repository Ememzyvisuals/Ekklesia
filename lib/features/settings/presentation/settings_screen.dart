import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/app_settings_service.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/groq_providers.dart';
import '../../../core/services/groq_usage_service.dart';
import '../../../core/services/user_groq_key_service.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../core/config/app_theme.dart';

/// Real settings screen — theme mode, language, voice engine info, sign
/// out, downloads management, and notifications. Credits is still listed
/// but not built out (flagged, not silently skipped).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static const _languages = [
    ('english', 'English (WazobiaVoice — James)'),
    ('hausa', 'Hausa (WazobiaVoice — Hauwa)'),
    ('igbo', 'Igbo (WazobiaVoice — Adaeze)'),
    ('pidgin', 'Pidgin (WazobiaVoice — Ngozi)'),
    ('yoruba', 'Yoruba (YarnGPT-local — Female)'),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final themeMode = ref.watch(themeModeProvider);
    final language = ref.watch(languageProvider);
    final user = AuthService.instance.currentUser;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.navSettings)),
      body: ListView(
        children: [
          if (user != null)
            ListTile(
              leading: const CircleAvatar(child: Icon(Icons.person)),
              title: Text(user.displayName ?? l10n.settingsDefaultUserName),
              subtitle: Text(user.email ?? ''),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/profile'),
            ),
          const Divider(),

          ListTile(
            leading: const Icon(Icons.videogame_asset_outlined),
            title: Text(l10n.settingsGames),
            subtitle: Text(l10n.settingsGamesSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/games'),
          ),
          const Divider(),

          ListTile(
            leading: const Icon(Icons.language),
            title: Text(l10n.settingsLanguageVoice),
            subtitle: Text(_languages.firstWhere((l) => l.$1 == language, orElse: () => _languages.first).$2),
            onTap: () => _showLanguagePicker(context, ref, language),
          ),

          const Divider(),
          ListTile(
            leading: const Icon(Icons.smart_toy_outlined),
            title: Text(l10n.settingsAiSectionTitle),
          ),
          FutureBuilder<String?>(
            future: ref.watch(userGroqKeyProvider.future),
            builder: (context, snapshot) {
              final key = snapshot.data;
              return ListTile(
                leading: Icon(key != null ? Icons.key_rounded : Icons.key_off_outlined),
                title: Text(l10n.settingsGroqKeyTitle),
                subtitle: key != null
                    ? Text(l10n.settingsGroqKeyUnlimitedSuffix(UserGroqKeyService.mask(key)))
                    : FutureBuilder<int>(
                        future: ref.watch(groqRemainingTodayProvider.future),
                        builder: (context, usageSnapshot) {
                          final remaining = usageSnapshot.data;
                          return Text(
                            remaining == null
                                ? l10n.settingsGroqKeyUsingShared
                                : l10n.settingsGroqKeyRemainingToday(remaining),
                          );
                        },
                      ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => _showGroqKeyDialog(context, ref, l10n, currentKey: key),
              );
            },
          ),

          const Divider(),
          ListTile(
            leading: const Icon(Icons.brightness_6),
            title: Text(l10n.settingsAppearance),
          ),
          RadioListTile<ThemeMode>(
            title: Text(l10n.settingsThemeSystem),
            value: ThemeMode.system,
            groupValue: themeMode,
            onChanged: (m) => ref.read(themeModeProvider.notifier).setMode(m!),
          ),
          RadioListTile<ThemeMode>(
            title: Text(l10n.settingsThemeLight),
            value: ThemeMode.light,
            groupValue: themeMode,
            onChanged: (m) => ref.read(themeModeProvider.notifier).setMode(m!),
          ),
          RadioListTile<ThemeMode>(
            title: Text(l10n.settingsThemeDark),
            value: ThemeMode.dark,
            groupValue: themeMode,
            onChanged: (m) => ref.read(themeModeProvider.notifier).setMode(m!),
          ),

          const Divider(),
          ListTile(
            leading: const Icon(Icons.download),
            title: Text(AppLocalizations.of(context)!.settingsDownloads),
            subtitle: Text(AppLocalizations.of(context)!.settingsDownloadsSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/downloads'),
          ),
          ListTile(
            leading: const Icon(Icons.notifications),
            title: Text(AppLocalizations.of(context)!.settingsNotifications),
            subtitle: Text(AppLocalizations.of(context)!.settingsNotificationsSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/notifications'),
          ),
          ListTile(
            leading: const Icon(Icons.bookmark_outline),
            title: Text(AppLocalizations.of(context)!.settingsBookmarks),
            subtitle: Text(AppLocalizations.of(context)!.settingsBookmarksSubtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/bookmarks'),
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(l10n.settingsCredits),
            subtitle: Text(l10n.settingsCreditsSubtitle),
          ),

          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: Text(AppLocalizations.of(context)!.commonSignOut, style: const TextStyle(color: Colors.red)),
            onTap: () async {
              await AuthService.instance.signOut();
              if (context.mounted) context.go('/login');
            },
          ),
        ],
      ),
    );
  }

  void _showLanguagePicker(BuildContext context, WidgetRef ref, String current) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _languages.map((l) => ListTile(
            title: Text(l.$2),
            trailing: current == l.$1 ? const Icon(Icons.check, color: AppColors.primary) : null,
            onTap: () {
              ref.read(languageProvider.notifier).setLanguage(l.$1);
              Navigator.of(context).pop();
            },
          )).toList(),
        ),
      ),
    );
  }

  void _showGroqKeyDialog(BuildContext context, WidgetRef ref, AppLocalizations l10n, {String? currentKey}) {
    final controller = TextEditingController();
    var obscure = true;
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: Text(l10n.settingsGroqKeyTitle),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  currentKey != null
                      ? l10n.settingsGroqKeyDialogCurrentSet(UserGroqKeyService.mask(currentKey))
                      : l10n.settingsGroqKeyDialogPrompt(GroqUsageService.dailyFreeLimit),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    hintText: 'gsk_...',
                    border: const OutlineInputBorder(),
                    isDense: true,
                    suffixIcon: IconButton(
                      icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setDialogState(() => obscure = !obscure),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                InkWell(
                  onTap: () => launchUrl(Uri.parse('https://console.groq.com/keys')),
                  child: const Text(
                    'console.groq.com/keys',
                    style: TextStyle(color: AppColors.primary, decoration: TextDecoration.underline),
                  ),
                ),
              ],
            ),
            actions: [
              if (currentKey != null)
                TextButton(
                  onPressed: () async {
                    await UserGroqKeyService.instance.clearKey();
                    ref.invalidate(userGroqKeyProvider);
                    if (context.mounted) Navigator.pop(context);
                  },
                  child: Text(l10n.settingsGroqKeyRemove),
                ),
              TextButton(onPressed: () => Navigator.pop(context), child: Text(l10n.commonCancel)),
              FilledButton(
                onPressed: () async {
                  final value = controller.text.trim();
                  if (value.isEmpty) {
                    Navigator.pop(context);
                    return;
                  }
                  await UserGroqKeyService.instance.setKey(value);
                  ref.invalidate(userGroqKeyProvider);
                  if (context.mounted) Navigator.pop(context);
                },
                child: Text(l10n.commonSave),
              ),
            ],
          );
        },
      ),
    );
  }
}
