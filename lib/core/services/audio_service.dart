import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// Identifies which TTS/audio engine produced a given clip.
/// Used to decide playback speed and any other source-specific handling.
enum AudioSource {
  wazobiaVoice, // primary TTS engine — plays at normal speed
  yarnGpt, // English (Emma) — plays slowed down, see [yarnGptPlaybackSpeed]
  humanRecording, // e.g. DCLM radio stream, sermon audio, YouTube live
  local, // bundled app sounds (button clicks, rewards, etc.)
}

/// Central audio playback service for the whole app.
///
/// Single source of truth for "what speed does this clip play at."
/// WazobiaVoice output is used as generated. YarnGPT's English voice (Emma)
/// was found to render too fast at its native rate, so it is always played
/// back at [yarnGptPlaybackSpeed] until/unless a better-tuned checkpoint
/// replaces it — keep this override even if the model improves, and only
/// remove it after a deliberate re-test.
class AudioService {
  AudioService._internal();
  static final AudioService instance = AudioService._internal();

  static const double yarnGptPlaybackSpeed = 0.5;
  static const double defaultPlaybackSpeed = 1.0;

  final AudioPlayer _player = AudioPlayer();

  AudioPlayer get player => _player;

  /// Bumped every time [play], [playQueue], or [stop] is called, so an
  /// in-flight [playQueue] loop can tell it's been superseded and stop
  /// advancing to its next chunk instead of talking over new audio.
  int _playToken = 0;

  /// Reports which queued chunk is currently playing during a [playQueue]
  /// call, as (index, total) — e.g. (0, 3) for the first of three chunks.
  /// Null when nothing queued is playing. Useful for a "part 2 of 5" label.
  final _queueProgressController = StreamController<(int, int)?>.broadcast();
  Stream<(int, int)?> get queueProgressStream =>
      _queueProgressController.stream;

  /// Plays a clip from [url], applying the correct speed for [source].
  ///
  /// [overrideSpeed] lets a caller (e.g. a user-facing speed slider) force
  /// a specific rate regardless of source; otherwise the source's default
  /// applies.
  Future<void> play({
    required String url,
    required AudioSource source,
    double? overrideSpeed,
  }) async {
    _playToken++;
    _queueProgressController.add(null);
    await _player.setUrl(url);
    final speed = overrideSpeed ?? speedForSource(source);
    await _player.setSpeed(speed);
    await _player.play();
  }

  /// Plays a sequence of clips back-to-back as one continuous listen —
  /// used for chunked TTS output (see [TtsService.synthesizeChunks]) where
  /// long text has been split into several clips that need to sound like
  /// a single uninterrupted reading rather than separate plays.
  ///
  /// [items] is an iterable/stream of `(url, source)` pairs so the caller
  /// can start playback on the first chunk as soon as it's ready without
  /// waiting for every chunk to finish generating first.
  ///
  /// Stops early (without error) if [stop] or another [play]/[playQueue]
  /// call supersedes this one mid-queue.
  Future<void> playQueue(Stream<(String url, AudioSource source)> items) async {
    final myToken = ++_playToken;
    var index = 0;

    // Materialize lazily: we still advance chunk-by-chunk as they arrive
    // from the stream, so a slow-to-generate later chunk doesn't block
    // the first one from starting.
    await for (final (url, source) in items) {
      if (myToken != _playToken) return; // superseded — stop advancing
      _queueProgressController.add((index, index + 1));
      await _player.setUrl(url);
      await _player.setSpeed(speedForSource(source));
      await _player.play();
      // Wait for this clip to finish before pulling/playing the next one.
      await _player.playerStateStream.firstWhere(
        (s) => s.processingState == ProcessingState.completed,
      );
      if (myToken != _playToken) return;
      index++;
    }
    if (myToken == _playToken) _queueProgressController.add(null);
  }

  /// Plays from a local asset path (bundled sounds — button clicks, rewards).
  Future<void> playAsset(String assetPath) async {
    _playToken++;
    _queueProgressController.add(null);
    await _player.setAsset(assetPath);
    await _player.setSpeed(defaultPlaybackSpeed);
    await _player.play();
  }

  double speedForSource(AudioSource source) {
    switch (source) {
      case AudioSource.yarnGpt:
        return yarnGptPlaybackSpeed;
      case AudioSource.wazobiaVoice:
      case AudioSource.humanRecording:
      case AudioSource.local:
        return defaultPlaybackSpeed;
    }
  }

  Future<void> pause() => _player.pause();
  Future<void> resume() => _player.play();

  Future<void> stop() async {
    _playToken++;
    _queueProgressController.add(null);
    await _player.stop();
  }

  Future<void> seek(Duration position) => _player.seek(position);

  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;

  Future<void> dispose() {
    _queueProgressController.close();
    return _player.dispose();
  }
}
