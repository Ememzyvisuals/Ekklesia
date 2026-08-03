import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/app_theme.dart';
import '../../../core/shared/result.dart';
import '../data/games_repository.dart';
import '../domain/game_entry.dart';
import 'game_webview_screen.dart';

class GamesScreen extends StatefulWidget {
  const GamesScreen({super.key});

  @override
  State<GamesScreen> createState() => _GamesScreenState();
}

class _GamesScreenState extends State<GamesScreen> {
  final _repository = GamesRepository();
  Result<List<GameEntry>> _result = const Result.loading();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _result = const Result.loading());
    final result = await _repository.fetchCatalog();
    if (mounted) setState(() => _result = result);
  }

  Future<void> _openGame(GameEntry game) async {
    if (game.isEmbeddable) {
      Navigator.of(context).push(MaterialPageRoute(
        builder: (_) =>
            GameWebViewScreen(title: game.title, url: game.embedUrl!),
      ));
      return;
    }
    if (game.launchUrl != null) {
      final uri = Uri.parse(game.launchUrl!);
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Games')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: switch (_result) {
          ResultLoading() => const Center(child: CircularProgressIndicator()),
          ResultFailure(failure: final f) =>
            _ErrorState(message: f.message, onRetry: _load),
          ResultSuccess(data: final games) => games.isEmpty
              ? const _EmptyState()
              : _GameGrid(games: games, onTap: _openGame),
        },
      ),
    );
  }
}

/// Genuine empty state — not a placeholder screen pretending games exist.
/// This is the real, expected state of the feature until entries are added
/// to Firestore's `games` collection.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 60),
        Icon(Icons.videogame_asset_outlined,
            size: 56, color: AppTheme.textSecondary(context)),
        const SizedBox(height: 20),
        Center(
          child: Text('No games yet',
              style: AppTypography.titleMedium(
                  color: AppTheme.textPrimary(context))),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            'We only add games where the developer has granted us '
            'permission to link or embed — nothing scraped, nothing added '
            'without a real license. Check back as new titles are approved.',
            textAlign: TextAlign.center,
            style: AppTypography.bodyMedium(
                color: AppTheme.textSecondary(context)),
          ),
        ),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 60),
        Icon(Icons.wifi_off, size: 48, color: AppColors.error),
        const SizedBox(height: 16),
        Center(child: Text(message, textAlign: TextAlign.center)),
        const SizedBox(height: 16),
        Center(
            child:
                ElevatedButton(onPressed: onRetry, child: const Text('Retry'))),
      ],
    );
  }
}

class _GameGrid extends StatelessWidget {
  const _GameGrid({required this.games, required this.onTap});
  final List<GameEntry> games;
  final ValueChanged<GameEntry> onTap;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 16,
        crossAxisSpacing: 16,
        childAspectRatio: 0.78,
      ),
      itemCount: games.length,
      itemBuilder: (context, i) {
        final game = games[i];
        return GestureDetector(
          onTap: () => onTap(game),
          child: Container(
            decoration: BoxDecoration(
              color: AppTheme.surface(context),
              borderRadius: BorderRadius.circular(20),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AspectRatio(
                  aspectRatio: 1.4,
                  child: CachedNetworkImage(
                    imageUrl: game.thumbnailUrl,
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        Container(color: AppColors.secondary),
                    errorWidget: (_, __, ___) => Container(
                      color: AppColors.secondary,
                      child: const Icon(Icons.videogame_asset_outlined),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(game.title,
                          style: AppTypography.titleSmall(
                              color: AppTheme.textPrimary(context)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 4),
                      Text('${game.category} · ${game.ageRating}',
                          style: AppTypography.caption(
                              color: AppTheme.textSecondary(context))),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
