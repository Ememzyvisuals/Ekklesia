import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/config/app_theme.dart';
import '../../../core/services/auth_service.dart';
import '../../../core/services/notification_worker.dart';
import '../../../l10n/generated/app_localizations.dart';

/// Notifications screen — the UI half of NotificationWorker, which already
/// existed (categorizing + deduping NotificationService's raw stream) but
/// had nowhere in the app rendering it. Settings previously listed this as
/// a stub ("Not built yet").
///
/// Honest scope note, inherited from NotificationWorker's own doc comment:
/// the actual *sending* of these pushes (live program started, verse
/// ready, etc.) is meant to happen server-side via Cloud Functions
/// triggering FCM — that's the Phase 2 backend, not implemented here. This
/// screen renders whatever NotificationService already has (foreground
/// FCM messages + Firestore history), it doesn't create the notifications.
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  IconData _iconFor(NotificationCategory category) {
    switch (category) {
      case NotificationCategory.todaysVerse:
        return Icons.menu_book;
      case NotificationCategory.todaysPrayer:
        return Icons.favorite_outline;
      case NotificationCategory.liveProgram:
        return Icons.live_tv;
      case NotificationCategory.upcomingProgram:
        return Icons.event;
      case NotificationCategory.downloadComplete:
        return Icons.download_done;
      case NotificationCategory.syncComplete:
        return Icons.sync;
      case NotificationCategory.other:
        return Icons.notifications_none;
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = AuthService.instance.currentUser?.uid;

    return Scaffold(
      appBar: AppBar(title: Text(AppLocalizations.of(context)!.notificationsTitle)),
      body: uid == null
          ? Center(child: Text(AppLocalizations.of(context)!.notificationsSignInPrompt))
          : StreamBuilder<List<CategorizedNotification>>(
              stream: NotificationWorker.instance.stream(uid),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'Could not load notifications: ${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.red),
                      ),
                    ),
                  );
                }
                final notifications = snapshot.data ?? [];
                if (notifications.isEmpty) {
                  return Center(
                    child: Text(
                      AppLocalizations.of(context)!.notificationsEmpty,
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: notifications.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final n = notifications[index];
                    return ListTile(
                      leading: Icon(
                        _iconFor(n.category),
                        color: n.read ? AppColors.textSecondary : AppColors.primary,
                      ),
                      title: Text(
                        n.title,
                        style: TextStyle(
                          fontWeight: n.read ? FontWeight.normal : FontWeight.bold,
                        ),
                      ),
                      subtitle: Text(n.body),
                      trailing: Text(
                        DateFormat('MMM d, h:mm a').format(n.createdAt),
                        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                      ),
                      onTap: n.read ? null : () => NotificationWorker.instance.markAsRead(n.id),
                    );
                  },
                );
              },
            ),
    );
  }
}
