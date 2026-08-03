import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'notification_service.dart';

/// Sits on top of [NotificationService] (which owns FCM token registration
/// and raw Firestore writes) and turns the raw `notifications` stream into
/// something the UI can consume directly: deduped by id, categorized by
/// type, with an unread count — without re-fetching or re-subscribing per
/// screen.
///
/// Per the spec's architecture, the actual *sending* of pushes (live
/// program started, today's verse ready, download complete, etc.) belongs
/// to Cloud Functions triggering FCM server-side — that's Phase 2, not
/// implemented here. What this worker does today: turn whatever
/// [NotificationService] already receives (via `onMessage` while the app
/// is foregrounded, or Firestore history for the badge count) into a
/// single categorized stream, and enforce the "never spam users" rule by
/// collapsing duplicate title+body pairs received within a short window.
enum NotificationCategory {
  todaysVerse,
  todaysPrayer,
  liveProgram,
  upcomingProgram,
  downloadComplete,
  syncComplete,
  other,
}

class CategorizedNotification {
  const CategorizedNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.category,
    required this.read,
    required this.createdAt,
  });

  final String id;
  final String title;
  final String body;
  final NotificationCategory category;
  final bool read;
  final DateTime createdAt;

  factory CategorizedNotification.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return CategorizedNotification(
      id: doc.id,
      title: data['title'] as String? ?? '',
      body: data['body'] as String? ?? '',
      category: _categorize(data),
      read: data['read'] as bool? ?? false,
      createdAt: data['created_at'] is Timestamp
          ? (data['created_at'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }

  static NotificationCategory _categorize(Map<String, dynamic> data) {
    final type = (data['data'] as Map?)?['type'] as String? ?? '';
    switch (type) {
      case 'todays_verse':
        return NotificationCategory.todaysVerse;
      case 'todays_prayer':
        return NotificationCategory.todaysPrayer;
      case 'live_program':
        return NotificationCategory.liveProgram;
      case 'upcoming_program':
        return NotificationCategory.upcomingProgram;
      case 'download_complete':
        return NotificationCategory.downloadComplete;
      case 'sync_complete':
        return NotificationCategory.syncComplete;
      default:
        return NotificationCategory.other;
    }
  }
}

class NotificationWorker {
  NotificationWorker._internal();
  static final NotificationWorker instance = NotificationWorker._internal();

  /// Recently-seen title+body pairs, to suppress an accidental duplicate
  /// delivery (FCM occasionally redelivers) within this window.
  final Map<String, DateTime> _recentlySeen = {};
  static const _dedupeWindow = Duration(seconds: 30);

  Stream<List<CategorizedNotification>> stream(String uid) {
    return NotificationService.instance
        .notificationsForUser(uid)
        .map((snapshot) {
      final now = DateTime.now();
      final result = <CategorizedNotification>[];
      for (final doc in snapshot.docs) {
        final notification = CategorizedNotification.fromDoc(doc);
        final dedupeKey = '${notification.title}|${notification.body}';
        final lastSeen = _recentlySeen[dedupeKey];
        if (lastSeen != null && now.difference(lastSeen) < _dedupeWindow) {
          continue;
        }
        _recentlySeen[dedupeKey] = now;
        result.add(notification);
      }
      return result;
    });
  }

  int unreadCount(List<CategorizedNotification> notifications) =>
      notifications.where((n) => !n.read).length;

  Future<void> markAsRead(String notificationId) =>
      NotificationService.instance.markAsRead(notificationId);
}
