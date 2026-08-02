import 'package:cloud_firestore/cloud_firestore.dart';

import '../config/app_config.dart';
import 'gradio_client.dart';

/// Logs TTS generation problems to Firestore's `worker_logs` collection
/// (same collection CleanupWorker already prunes on a schedule — see
/// `WORKERS.md` — so this doesn't introduce a new unbounded collection).
///
/// Every call is fire-and-forget and swallows its own errors: a logging
/// failure must never be the reason TTS playback breaks. This exists
/// specifically because cold-start/rate-limit failures were previously
/// silent — a person hearing "no audio" with zero diagnostic trail was
/// the actual bug being fixed here, not just adding retries.
class TtsErrorLogger {
  TtsErrorLogger._internal();
  static final TtsErrorLogger instance = TtsErrorLogger._internal();

  final _collection = FirebaseFirestore.instance.collection(AppConfig.workerLogsCollection);

  Future<void> logRetry({
    required String source, // 'wazobiaVoice' | 'yarnGpt'
    required GradioErrorType errorType,
    required int attempt,
    required int maxAttempts,
    required String message,
  }) async {
    await _write({
      'worker': 'tts',
      'level': 'warn',
      'event': 'retry',
      'source': source,
      'error_type': errorType.name,
      'attempt': attempt,
      'max_attempts': maxAttempts,
      'message': message,
    });
  }

  Future<void> logFailure({
    required String source,
    required GradioErrorType errorType,
    required int attemptsMade,
    required String message,
  }) async {
    await _write({
      'worker': 'tts',
      'level': 'error',
      'event': 'failed',
      'source': source,
      'error_type': errorType.name,
      'attempts_made': attemptsMade,
      'message': message,
    });
  }

  Future<void> _write(Map<String, dynamic> fields) async {
    try {
      await _collection.add({
        ...fields,
        'created_at': FieldValue.serverTimestamp(),
      });
    } catch (_) {
      // Logging must never be the reason playback fails harder — if this
      // write fails (offline, permissions, whatever), just drop it.
    }
  }
}
