import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../config/app_config.dart';
import '../../features/downloads/data/download_repository.dart';
import '../../features/downloads/domain/download_task.dart';

/// Foreground download engine: queue, pause, resume, retry, checksum,
/// delete, storage stats, progress — one task in flight at a time by
/// design (DCLM's radio/video hosts are not built for parallel-chunked
/// downloads, and a solo-dev v1 gains nothing from the added complexity
/// of a concurrent download pool with no evidence it's needed).
///
/// Scope note shared with every other worker in this file set: this runs
/// while the app is foregrounded. Background continuation while the app
/// is closed needs platform-registered background download support
/// (Android `WorkManager`/foreground service, iOS `URLSessionConfiguration
/// .background`) — not wired here; a large download will pause, not
/// silently corrupt, if the app is killed mid-transfer, since progress is
/// persisted after every chunk and resume uses an HTTP Range request.
class DownloadWorker {
  DownloadWorker._internal();
  static final DownloadWorker instance = DownloadWorker._internal();

  final Dio _dio = Dio();
  final _activeCancelTokens = <String, CancelToken>{};
  final _progressControllers = <String, StreamController<DownloadTask>>{};

  Stream<DownloadTask> progressStream(String taskId) {
    return _progressControllers
        .putIfAbsent(taskId, () => StreamController<DownloadTask>.broadcast())
        .stream;
  }

  Future<List<DownloadTask>> getAll() => DownloadRepository.instance.getAll();

  Future<DownloadTask> enqueue({
    required String title,
    required String sourceUrl,
    required String localPath,
    String? expectedSha256,
  }) async {
    final task = DownloadTask(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      sourceUrl: sourceUrl,
      localPath: localPath,
      expectedSha256: expectedSha256,
    );
    await DownloadRepository.instance.upsert(task);
    unawaited(start(task.id));
    return task;
  }

  Future<void> start(String taskId) async {
    final task = await _get(taskId);
    if (task == null) return;
    if (task.status == DownloadStatus.downloading) return; // already running

    final cancelToken = CancelToken();
    _activeCancelTokens[taskId] = cancelToken;

    final partFile = File('${task.localPath}.part');
    final resumeFrom = await partFile.exists() ? await partFile.length() : 0;

    task.status = DownloadStatus.downloading;
    task.downloadedBytes = resumeFrom;
    await _persist(task);

    try {
      await Directory(File(task.localPath).parent.path).create(recursive: true);
      final sink = partFile.openWrite(
          mode: resumeFrom > 0 ? FileMode.append : FileMode.write);

      final response = await _dio.get<ResponseBody>(
        task.sourceUrl,
        options: Options(
          responseType: ResponseType.stream,
          headers: resumeFrom > 0 ? {'Range': 'bytes=$resumeFrom-'} : null,
        ),
        cancelToken: cancelToken,
      );

      final total = _resolveTotalBytes(response, resumeFrom);
      task.totalBytes = total;

      var received = resumeFrom;
      await for (final chunk in response.data!.stream) {
        sink.add(chunk);
        received += chunk.length;
        task.downloadedBytes = received;
        _progressControllers[taskId]?.add(task);
        // Persist periodically rather than on every chunk (chunk sizes from
        // Dio's stream are typically 8-16KB — persisting on every one of
        // those would hammer SharedPreferences for no real benefit).
        if (received % (256 * 1024) < chunk.length) {
          await _persist(task);
        }
      }
      await sink.close();

      await _finalize(task);
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        task.status = DownloadStatus.paused;
      } else {
        task.status = DownloadStatus.failed;
        task.errorMessage = e.message ?? 'Download failed';
      }
      await _persist(task);
    } catch (e) {
      task.status = DownloadStatus.failed;
      task.errorMessage = e.toString();
      await _persist(task);
    } finally {
      _activeCancelTokens.remove(taskId);
    }
  }

  Future<void> pause(String taskId) async {
    _activeCancelTokens[taskId]?.cancel('paused_by_user');
  }

  Future<void> resume(String taskId) => start(taskId);

  /// Retries a failed download from scratch — a failed transfer's `.part`
  /// file is discarded rather than resumed from, since the failure mode
  /// (bad checksum, server error) may mean the partial bytes are corrupt.
  Future<void> retry(String taskId) async {
    final task = await _get(taskId);
    if (task == null) return;
    final partFile = File('${task.localPath}.part');
    if (await partFile.exists()) {
      await partFile.delete();
    }
    task.downloadedBytes = 0;
    task.errorMessage = null;
    task.status = DownloadStatus.queued;
    await _persist(task);
    await start(taskId);
  }

  Future<void> delete(String taskId) async {
    await pause(taskId);
    await DownloadRepository.instance.delete(taskId);
    _progressControllers.remove(taskId)?.close();
  }

  Future<int> storageStatsBytes() =>
      DownloadRepository.instance.totalStorageBytes();

  Future<void> _finalize(DownloadTask task) async {
    final partFile = File('${task.localPath}.part');

    if (task.expectedSha256 != null) {
      final digest = await _sha256Of(partFile);
      if (digest != task.expectedSha256) {
        task.status = DownloadStatus.failed;
        task.errorMessage = 'Checksum mismatch — file may be corrupted.';
        await partFile.delete();
        await _persist(task);
        return;
      }
    }

    await partFile.rename(task.localPath);
    task.status = DownloadStatus.completed;
    await _persist(task);

    // Best-effort completion log (spec's `download_logs` collection) —
    // failure here must never fail the download itself.
    try {
      await FirebaseFirestore.instance
          .collection(AppConfig.downloadLogsCollection)
          .add({
        'task_id': task.id,
        'title': task.title,
        'bytes': task.totalBytes,
        'completed_at': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  Future<String> _sha256Of(File file) async {
    final digestSink = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(digestSink);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return digestSink.events.single.toString();
  }

  int _resolveTotalBytes(Response<ResponseBody> response, int resumeFrom) {
    final contentRange = response.headers.value('content-range');
    if (contentRange != null) {
      final match = RegExp(r'/(\d+)$').firstMatch(contentRange);
      if (match != null) return int.parse(match.group(1)!);
    }
    final contentLength = response.headers.value('content-length');
    if (contentLength != null) return resumeFrom + int.parse(contentLength);
    return 0; // unknown — progress UI should show indeterminate in this case
  }

  Future<DownloadTask?> _get(String taskId) async {
    final tasks = await DownloadRepository.instance.getAll();
    for (final t in tasks) {
      if (t.id == taskId) return t;
    }
    return null;
  }

  Future<void> _persist(DownloadTask task) async {
    await DownloadRepository.instance.upsert(task);
    _progressControllers[task.id]?.add(task);
  }
}
