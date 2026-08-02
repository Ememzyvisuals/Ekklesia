import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/auth_service.dart';
import '../../../core/config/app_theme.dart';
import '../data/avatar_service.dart';
import 'avatar_picker.dart';

const List<String> _ageRanges = ['Under 18', '18-24', '25-34', '35-44', '45-54', '55+'];
const List<String> _languages = ['English', 'Yoruba', 'Hausa', 'Igbo', 'Nigerian Pidgin'];

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _bioController = TextEditingController();

  AvatarGender _gender = AvatarGender.male;
  String _ageRange = _ageRanges[1];
  String _preferredLanguage = _languages[0];
  String? _selectedAvatarId;

  bool _loading = false;
  String? _error;

  Future<void> _signUp() async {
    if (_nameController.text.trim().isEmpty) {
      setState(() => _error = 'Please enter your name.');
      return;
    }
    if (_passwordController.text.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AuthService.instance.signUp(
        email: _emailController.text.trim(),
        password: _passwordController.text,
        displayName: _nameController.text.trim(),
        gender: _gender,
        ageRange: _ageRange,
        preferredLanguage: _preferredLanguage.toLowerCase().replaceAll(' ', '_'),
        bio: _bioController.text.trim(),
        avatarId: _selectedAvatarId,
        // No photo upload flow yet — user either picked a default avatar
        // above or AuthService assigns one deterministically. Photo upload
        // is a real follow-up (needs Firebase Storage wiring), not silently
        // faked here.
      );
      // Router redirect handles navigation on auth state change.
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create Account')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Name', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passwordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 20),
            Text('Gender', style: AppTypography.titleSmall(color: AppTheme.textPrimary(context))),
            const SizedBox(height: 8),
            SegmentedButton<AvatarGender>(
              segments: const [
                ButtonSegment(value: AvatarGender.male, label: Text('Male')),
                ButtonSegment(value: AvatarGender.female, label: Text('Female')),
              ],
              selected: {_gender},
              onSelectionChanged: (s) => setState(() {
                _gender = s.first;
                _selectedAvatarId = null; // avatar catalog is gender-filtered; clear stale pick
              }),
            ),
            const SizedBox(height: 20),
            Text('Age group', style: AppTypography.titleSmall(color: AppTheme.textPrimary(context))),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _ageRange,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: _ageRanges.map((a) => DropdownMenuItem(value: a, child: Text(a))).toList(),
              onChanged: (v) => setState(() => _ageRange = v ?? _ageRange),
            ),
            const SizedBox(height: 20),
            Text('Preferred language', style: AppTypography.titleSmall(color: AppTheme.textPrimary(context))),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              initialValue: _preferredLanguage,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: _languages.map((l) => DropdownMenuItem(value: l, child: Text(l))).toList(),
              onChanged: (v) => setState(() => _preferredLanguage = v ?? _preferredLanguage),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _bioController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Bio (optional)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),
            Text('Choose an avatar (optional)',
                style: AppTypography.titleSmall(color: AppTheme.textPrimary(context))),
            const SizedBox(height: 4),
            Text(
              'Skip this and we\'ll assign one automatically.',
              style: AppTypography.bodySmall(color: AppTheme.textSecondary(context)),
            ),
            const SizedBox(height: 12),
            AvatarPicker(
              initialGender: _gender,
              selectedId: _selectedAvatarId,
              onSelected: (option) => setState(() => _selectedAvatarId = option.id),
            ),
            const SizedBox(height: 20),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            ElevatedButton(
              onPressed: _loading ? null : _signUp,
              child: _loading
                  ? const SizedBox(
                      height: 18, width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Sign Up'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => context.go('/login'),
              child: const Text('Already have an account? Sign in'),
            ),
          ],
        ),
      ),
    );
  }
}
