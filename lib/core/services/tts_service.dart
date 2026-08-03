import 'dart:async';
import 'dart:math';

import '../config/app_config.dart';
import 'gradio_client.dart';
import 'audio_service.dart';
import 'tts_error_logger.dart';

enum EkklesiaLanguage { english, hausa, igbo, pidgin, yoruba }

extension EkklesiaLanguageCode on EkklesiaLanguage {
  String get code {
    switch (this) {
      case EkklesiaLanguage.english:
        return 'english';
      case EkklesiaLanguage.hausa:
        return 'hausa';
      case EkklesiaLanguage.igbo:
        return 'igbo';
      case EkklesiaLanguage.pidgin:
        return 'pidgin';
      case EkklesiaLanguage.yoruba:
        return 'yoruba';
    }
  }
}

/// Result of a TTS generation — the playable URL and which [AudioSource]
/// produced it, so [AudioService] applies the right playback speed.
class TtsResult {
  TtsResult({required this.audioUrl, required this.source});
  final String audioUrl;
  final AudioSource source;
}

/// Thrown when TTS generation fails after exhausting retries — carries
/// the underlying [GradioErrorType] so UI can show something more useful
/// than "something went wrong" (e.g. "the voice service is waking up,
/// try again in a moment" for a cold start vs. a generic error).
class TtsGenerationException implements Exception {
  TtsGenerationException(this.type, this.message, {required this.attemptsMade});
  final GradioErrorType type;
  final String message;
  final int attemptsMade;

  @override
  String toString() =>
      'TtsGenerationException(${type.name}, after $attemptsMade attempts): $message';
}

/// Routes text-to-speech requests to the correct engine per language:
///
/// - English, Hausa, Igbo, Pidgin -> WazobiaVoice (James / Hauwa / Adaeze / Ngozi)
/// - Yoruba -> YarnGPT-local (female voice) — WazobiaVoice's Yoruba was
///   judged weaker in listening tests (too fast), so this is a deliberate
///   split, not an oversight. Revisit only after a real side-by-side
///   re-test if WazobiaVoice's Yoruba ever improves.
///
/// Free-tier HF Spaces sleep after inactivity and occasionally rate-limit
/// under load — [synthesizeWithRetry] (used by everything else in this
/// class) retries cold-starts/rate-limits/timeouts with backoff and logs
/// every retry/failure via [TtsErrorLogger], instead of surfacing the
/// first transient hiccup as a hard failure with no diagnostic trail.
class TtsService {
  TtsService._internal();
  static final TtsService instance = TtsService._internal();

  final GradioClient _wazobiaClient =
      GradioClient(AppConfig.wazobiaVoiceSpaceUrl);
  final GradioClient _yarnGptClient = GradioClient(AppConfig.yarnGptSpaceUrl);

  static const _maxAttempts = 3;
  static const _baseBackoff = Duration(seconds: 3);

  Future<TtsResult> synthesize({
    required String text,
    required EkklesiaLanguage language,
  }) {
    return synthesizeWithRetry(text: text, language: language);
  }

  /// Synthesizes one chunk of text, retrying retryable failures
  /// ([GradioClientException.isRetryable]) with exponential backoff +
  /// jitter, up to [_maxAttempts] total attempts. Every retry and any
  /// final failure is logged via [TtsErrorLogger] — cold starts and rate
  /// limits are common enough on a free-tier Space that silently eating
  /// them (or silently failing) both make debugging "why no audio"
  /// impossible after the fact.
  Future<TtsResult> synthesizeWithRetry({
    required String text,
    required EkklesiaLanguage language,
  }) async {
    final source =
        language == EkklesiaLanguage.yoruba ? 'yarnGpt' : 'wazobiaVoice';
    Object? lastError;

    for (var attempt = 1; attempt <= _maxAttempts; attempt++) {
      try {
        if (language == EkklesiaLanguage.yoruba) {
          return await _synthesizeYoruba(text);
        }
        return await _synthesizeWazobia(text, language);
      } on GradioClientException catch (e) {
        lastError = e;
        final isLastAttempt = attempt == _maxAttempts;
        if (!e.isRetryable || isLastAttempt) {
          await TtsErrorLogger.instance.logFailure(
            source: source,
            errorType: e.type,
            attemptsMade: attempt,
            message: e.message,
          );
          throw TtsGenerationException(e.type, e.message,
              attemptsMade: attempt);
        }
        await TtsErrorLogger.instance.logRetry(
          source: source,
          errorType: e.type,
          attempt: attempt,
          maxAttempts: _maxAttempts,
          message: e.message,
        );
        await Future.delayed(_backoffFor(attempt, e.type));
      }
    }

    // Unreachable in practice (the loop always returns or throws), but
    // keeps the analyzer happy about a guaranteed return/throw.
    throw TtsGenerationException(
      GradioErrorType.unknown,
      'TTS generation failed after $_maxAttempts attempts: $lastError',
      attemptsMade: _maxAttempts,
    );
  }

  Duration _backoffFor(int attempt, GradioErrorType type) {
    // Rate limits and cold starts benefit from a longer wait than a plain
    // timeout/network blip — no point hammering a Space that just told us
    // it's still booting.
    final multiplier = switch (type) {
      GradioErrorType.spaceStarting => 3,
      GradioErrorType.rateLimited => 2,
      _ => 1,
    };
    final jitterMs = Random().nextInt(500);
    return Duration(
      milliseconds:
          _baseBackoff.inMilliseconds * attempt * multiplier + jitterMs,
    );
  }

  /// Splits [text] into speakable chunks under [AppConfig.wazobiaVoiceMaxChars]
  /// (WazobiaVoice's underlying Chatterbox model silently truncates/pads
  /// long input to a fixed-length clip instead of erroring — this is what
  /// produces a constant ~40s output no matter how long the prompt is) and
  /// synthesizes each chunk in order, retrying transient failures per
  /// chunk via [synthesizeWithRetry].
  ///
  /// For chapter-length text where gapless playback matters, prefer
  /// [BibleTTSQueue] (features/bible/data/bible_tts_queue.dart) instead —
  /// it uses [chunkText] + [synthesizeWithRetry] under the hood but adds
  /// look-ahead prefetching so chunk N+1 generates while chunk N plays,
  /// rather than generating strictly one-at-a-time as this method does.
  Stream<TtsResult> synthesizeChunks({
    required String text,
    required EkklesiaLanguage language,
  }) async* {
    for (final chunk in chunkText(text)) {
      if (chunk.trim().isEmpty) continue;
      yield await synthesizeWithRetry(text: chunk, language: language);
    }
  }

  /// Splits [text] into pieces no longer than [AppConfig.wazobiaVoiceMaxChars],
  /// breaking on sentence boundaries first, then falling back to
  /// whitespace, so a chunk never cuts off mid-word or mid-sentence if it
  /// can be avoided. Pure text operation, no network — exposed publicly
  /// so [BibleTTSQueue] can plan its prefetch schedule up front.
  List<String> chunkText(String text) =>
      _splitIntoChunks(text, AppConfig.wazobiaVoiceMaxChars);

  List<String> _splitIntoChunks(String text, int maxChars) {
    final trimmed = text.trim();
    if (trimmed.length <= maxChars) return [trimmed];

    final sentences = trimmed
        .split(RegExp(r'(?<=[.!?])\s+'))
        .where((s) => s.trim().isNotEmpty)
        .toList();

    final chunks = <String>[];
    var current = StringBuffer();

    void flush() {
      if (current.isNotEmpty) {
        chunks.add(current.toString().trim());
        current = StringBuffer();
      }
    }

    for (final sentence in sentences) {
      if (sentence.length > maxChars) {
        flush();
        final words = sentence.split(RegExp(r'\s+'));
        var wordChunk = StringBuffer();
        for (final word in words) {
          final candidateLength =
              wordChunk.length + (wordChunk.isEmpty ? 0 : 1) + word.length;
          if (candidateLength > maxChars && wordChunk.isNotEmpty) {
            chunks.add(wordChunk.toString().trim());
            wordChunk = StringBuffer();
          }
          if (wordChunk.isNotEmpty) wordChunk.write(' ');
          wordChunk.write(word);
        }
        if (wordChunk.isNotEmpty) chunks.add(wordChunk.toString().trim());
        continue;
      }

      final candidateLength =
          current.length + (current.isEmpty ? 0 : 1) + sentence.length;
      if (candidateLength > maxChars && current.isNotEmpty) {
        flush();
      }
      if (current.isNotEmpty) current.write(' ');
      current.write(sentence);
    }
    flush();

    return chunks;
  }

  Future<TtsResult> _synthesizeWazobia(
      String text, EkklesiaLanguage language) async {
    final persona = AppConfig.wazobiaVoicePersonaByLanguage[language.code];
    if (persona == null) {
      throw Exception(
          'No WazobiaVoice persona configured for ${language.code}');
    }

    // Confirmed order from the real Space API docs:
    // (text, voice_name, exaggeration, cfg_weight)
    final result = await _wazobiaClient.call(
      apiName: AppConfig.wazobiaVoiceApiName,
      data: [
        text,
        persona,
        AppConfig.wazobiaVoiceExaggeration,
        AppConfig.wazobiaVoiceCfgWeight,
      ],
    );

    final audioUrl = _extractAudioUrl(result);
    return TtsResult(audioUrl: audioUrl, source: AudioSource.wazobiaVoice);
  }

  Future<TtsResult> _synthesizeYoruba(String text) async {
    final result = await _yarnGptClient.call(
      apiName: AppConfig.yarnGptLocalApiName,
      data: ['Yoruba', text, AppConfig.yarnGptYorubaSpeaker],
    );

    final audioUrl = _extractAudioUrl(result);
    return TtsResult(audioUrl: audioUrl, source: AudioSource.yarnGpt);
  }

  /// Gradio audio outputs typically come back as a map like
  /// `{"path": "...", "url": "...", ...}` inside the result list.
  /// Adjust this if the actual Space returns a different shape once
  /// you check "Use via API".
  String _extractAudioUrl(List<dynamic> result) {
    if (result.isEmpty) {
      throw Exception('Empty result from TTS Space');
    }
    final first = result.first;
    if (first is Map && first['url'] != null) {
      return first['url'] as String;
    }
    if (first is String) {
      return first;
    }
    throw Exception('Unexpected TTS result shape: $result');
  }
}
