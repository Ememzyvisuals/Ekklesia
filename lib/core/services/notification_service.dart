import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Push notifications via Firebase Cloud Messaging — live-program alerts,
/// Impact Academy reminders, prayer/reading streak nudges (per Volume 8
/// section 10). Also stores notification history in Firestore's
/// `notifications` collection so the in-app notifications list has
/// something to read even for notifications received while the app
/// was closed.
class NotificationService {
  NotificationService._internal();
  static final NotificationService instance = NotificationService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;

  StreamSubscription<String>? _tokenRefreshSub;
  StreamSubscription<RemoteMessage>? _onMessageSub;
  String? _initializedForUid;

  /// Safe to call every time `main.dart`'s auth-state listener fires with
  /// a non-null user — which can happen more than once per app session
  /// (sign out, then sign back in, without restarting the app). The
  /// previous version re-subscribed to `onTokenRefresh`/`onMessage` on
  /// every call without ever cancelling the prior subscription, so doing
  /// exactly that (sign out, sign back in) would leave two listeners
  /// running — every incoming push would get recorded twice in
  /// Firestore's `notifications` collection, tripling on a third
  /// sign-in/out cycle, and so on. Guards against both re-initializing
  /// for the same uid twice in a row, and against leaking the previous
  /// uid's listeners if a different user signs in on the same device.
  Future<void> initialize({required String uid}) async {
    if (_initializedForUid == uid) return; // already set up for this user

    await _tokenRefreshSub?.cancel();
    await _onMessageSub?.cancel();

    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      _initializedForUid = uid; // still mark as handled — don't nag or retry immediately
      return;
    }

    final token = await _messaging.getToken();
    if (token != null) {
      await _saveTokenToUser(uid, token);
    }

    _tokenRefreshSub = _messaging.onTokenRefresh.listen((newToken) => _saveTokenToUser(uid, newToken));
    _onMessageSub = FirebaseMessaging.onMessage.listen((message) => _recordNotification(uid, message));

    _initializedForUid = uid;
  }

  Future<void> _saveTokenToUser(String uid, String token) {
    return FirebaseFirestore.instance.collection('users').doc(uid).update({
      'fcm_token': token,
    });
  }

  Future<void> _recordNotification(String uid, RemoteMessage message) {
    return FirebaseFirestore.instance.collection('notifications').add({
      'uid': uid,
      'title': message.notification?.title ?? '',
      'body': message.notification?.body ?? '',
      'data': message.data,
      'read': false,
      'created_at': FieldValue.serverTimestamp(),
    });
  }

  Future<void> markAsRead(String notificationId) {
    return FirebaseFirestore.instance
        .collection('notifications')
        .doc(notificationId)
        .update({'read': true});
  }

  Stream<QuerySnapshot> notificationsForUser(String uid) {
    return FirebaseFirestore.instance
        .collection('notifications')
        .where('uid', isEqualTo: uid)
        .orderBy('created_at', descending: true)
        .snapshots();
  }
}
