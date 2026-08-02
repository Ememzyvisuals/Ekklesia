import 'package:flutter/material.dart';

import '../../../core/config/app_theme.dart';
import '../../../core/services/auth_service.dart';
import '../../auth/data/avatar_service.dart';
import '../../auth/presentation/avatar_picker.dart';
import '../data/profile_repository.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _repository = ProfileRepository();

  String get _uid => AuthService.instance.currentUser?.uid ?? '';

  Future<void> _editBio(UserProfile profile) async {
    final controller = TextEditingController(text: profile.bio);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit bio'),
        content: TextField(controller: controller, maxLines: 3, autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result != null) {
      await _repository.updateProfile(_uid, bio: result);
    }
  }

  Future<void> _editAvatar(UserProfile profile) async {
    final gender = profile.gender == 'female' ? AvatarGender.female : AvatarGender.male;
    String? picked = profile.avatarId;
    await showModalBottomSheet(
      context: context,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: AvatarPicker(
          initialGender: gender,
          selectedId: profile.avatarId,
          onSelected: (option) async {
            picked = option.id;
            await _repository.updateProfile(_uid, avatarId: option.id);
            if (context.mounted) Navigator.pop(context);
          },
        ),
      ),
    );
    // picked is captured for clarity even though updateProfile already ran
    // inside onSelected — avoids a second, redundant write here.
    picked;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: StreamBuilder<UserProfile?>(
        stream: _repository.watch(_uid),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final profile = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.all(24),
            children: [
              Center(
                child: GestureDetector(
                  onTap: () => _editAvatar(profile),
                  child: Stack(
                    children: [
                      AvatarView(avatarId: profile.avatarId, photoUrl: profile.photoUrl, size: 96),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(color: AppColors.accent, shape: BoxShape.circle),
                          child: const Icon(Icons.edit, size: 16, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(profile.displayName,
                    style: AppTypography.titleLarge(color: AppTheme.textPrimary(context))),
              ),
              Center(
                child: Text(profile.email,
                    style: AppTypography.bodyMedium(color: AppTheme.textSecondary(context))),
              ),
              const SizedBox(height: 24),
              ListTile(
                title: const Text('Bio'),
                subtitle: Text(profile.bio.isEmpty ? 'Add a short bio' : profile.bio),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => _editBio(profile),
              ),
              ListTile(
                title: const Text('Age group'),
                subtitle: Text(profile.ageRange ?? 'Not set'),
              ),
              ListTile(
                title: const Text('Preferred language'),
                subtitle: Text(profile.preferredLanguage),
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => AuthService.instance.signOut(),
                icon: const Icon(Icons.logout),
                label: const Text('Sign out'),
              ),
            ],
          );
        },
      ),
    );
  }
}
