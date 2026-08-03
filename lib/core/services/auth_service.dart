import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../features/auth/data/avatar_service.dart';
import 'ai_config.dart';

/// Wraps Firebase Authentication (email/password, per Volume 8 — Google
/// Sign-In noted as future-ready but not required for v1).
/// On successful signup, also creates the corresponding `users` Firestore
/// document per the schema in Volume 8.
class AuthService {
  AuthService._internal();
  static final AuthService instance = AuthService._internal();

  FirebaseAuth get _auth => FirebaseAuth.instance;

  User? get currentUser => _auth.currentUser;
  Stream<User?> get authStateChanges => _auth.authStateChanges();
  bool get isSignedIn => _auth.currentUser != null;

  /// Firebase ID token for the signed-in user, used as a Bearer token
  /// against the Cloudflare Worker Groq proxy (see `cloudflare/groq-proxy/`
  /// and `groq_service.dart`) — the Worker verifies this token's signature
  /// against Google's public JWKS itself, since it isn't a Firebase
  /// callable and doesn't get `request.auth` for free the way Cloud
  /// Functions callables do. Returns null if nobody's signed in.
  Future<String?> getIdToken() =>
      _auth.currentUser?.getIdToken() ?? Future.value(null);

  /// [gender], [ageRange], and [preferredLanguage] are required per the
  /// spec's Authentication section. [bio] and [photoUrl] are optional. If
  /// the user explicitly chose one in the AvatarPicker, pass its id as
  /// [avatarId] — that takes priority. If [avatarId] and [photoUrl] are both
  /// omitted, a default illustrated avatar is assigned deterministically
  /// from [gender] + the new user's uid (see AvatarService.pickDefault) —
  /// "generate default illustrated Christian avatars when users skip
  /// uploading photos" is a concrete requirement, not decorative.
  Future<UserCredential> signUp({
    required String email,
    required String password,
    required String displayName,
    required AvatarGender gender,
    required String ageRange,
    required String preferredLanguage,
    String bio = '',
    String? photoUrl,
    String? avatarId,
  }) async {
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    await credential.user?.updateDisplayName(displayName);

    final resolvedAvatarId = photoUrl != null
        ? null
        : (avatarId ??
            AvatarService.instance
                .pickDefault(gender: gender, seed: credential.user!.uid)
                .id);

    await FirebaseFirestore.instance
        .collection('users')
        .doc(credential.user!.uid)
        .set({
      'uid': credential.user!.uid,
      'email': email,
      'display_name': displayName,
      'photo_url': photoUrl,
      'avatar_id': resolvedAvatarId,
      'bio': bio,
      'gender': gender.name,
      'age_range': ageRange,
      'preferred_language': preferredLanguage,
      'created_at': FieldValue.serverTimestamp(),
      'updated_at': FieldValue.serverTimestamp(),
      'last_login': FieldValue.serverTimestamp(),
      'theme': 'system',
      'text_scale': 1.0,
    });

    // main()'s AIConfig.verify() ran before sign-in, when groqModels
    // (auth-required) always fails open to the default model. Re-run it
    // now that we have a signed-in user, so model verification actually
    // gets a chance to succeed. Fire-and-forget: chat still works with the
    // default model if this fails too.
    unawaited(AIConfig.instance.verify());

    return credential;
  }

  Future<UserCredential> signIn(
      {required String email, required String password}) async {
    final credential = await _auth.signInWithEmailAndPassword(
        email: email, password: password);
    await FirebaseFirestore.instance
        .collection('users')
        .doc(credential.user!.uid)
        .update({
      'last_login': FieldValue.serverTimestamp(),
    });
    unawaited(AIConfig.instance.verify());
    return credential;
  }

  Future<void> signOut() => _auth.signOut();

  Future<void> sendPasswordReset(String email) =>
      _auth.sendPasswordResetEmail(email: email);
}
