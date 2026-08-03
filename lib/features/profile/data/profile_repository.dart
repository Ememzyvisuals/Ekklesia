import 'package:cloud_firestore/cloud_firestore.dart';

/// Reads/writes the same `users/{uid}` document AuthService.signUp creates.
/// Kept as its own repository (rather than more methods on AuthService)
/// because auth and profile-editing are different responsibilities — auth
/// creates the account once, profile is read/edited repeatedly afterward.
class UserProfile {
  const UserProfile({
    required this.uid,
    required this.displayName,
    required this.email,
    required this.bio,
    required this.gender,
    required this.ageRange,
    required this.preferredLanguage,
    this.photoUrl,
    this.avatarId,
  });

  final String uid;
  final String displayName;
  final String email;
  final String bio;
  final String? gender;
  final String? ageRange;
  final String preferredLanguage;
  final String? photoUrl;
  final String? avatarId;

  factory UserProfile.fromFirestore(String uid, Map<String, dynamic> data) =>
      UserProfile(
        uid: uid,
        displayName: data['display_name'] as String? ?? '',
        email: data['email'] as String? ?? '',
        bio: data['bio'] as String? ?? '',
        gender: data['gender'] as String?,
        ageRange: data['age_range'] as String?,
        preferredLanguage: data['preferred_language'] as String? ?? 'english',
        photoUrl: data['photo_url'] as String?,
        avatarId: data['avatar_id'] as String?,
      );
}

class ProfileRepository {
  ProfileRepository({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Stream<UserProfile?> watch(String uid) {
    return _firestore.collection('users').doc(uid).snapshots().map((doc) {
      if (!doc.exists) return null;
      return UserProfile.fromFirestore(uid, doc.data()!);
    });
  }

  Future<void> updateProfile(
    String uid, {
    String? displayName,
    String? bio,
    String? avatarId,
  }) async {
    final updates = <String, dynamic>{
      'updated_at': FieldValue.serverTimestamp()
    };
    if (displayName != null) updates['display_name'] = displayName;
    if (bio != null) updates['bio'] = bio;
    if (avatarId != null) {
      updates['avatar_id'] = avatarId;
      updates['photo_url'] =
          null; // picking a default avatar clears any uploaded photo
    }
    await _firestore.collection('users').doc(uid).update(updates);
  }
}
