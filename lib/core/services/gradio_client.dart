import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Generic client for calling a Gradio Space's auto-generated REST API.
///
/// Gradio's HTTP API is a two-step flow:
///   1. POST to `/gradio_api/call/{api_name}` with the input data -> returns
///      an event id (as JSON: {"event_id": "..."}).
///   2. GET `/gradio_api/call/{api_name}/{event_id}` -> streams
///      server-sent events; the final "complete" event contains the
///      actual result data.
///
/// This wraps both steps into one call. Exact `apiName` values and the
/// order/shape of `data` depend on the specific Space — check that
/// Space's "Use via API" page (bottom of the Space's UI) to confirm
/// before wiring up a new endpoint.
///
/// Free-tier HF Spaces sleep after inactivity and take anywhere from a
/// few seconds to ~60s+ to wake back up on the next call — that shows up
/// here as either a slow-but-eventually-successful call, or a 503 while
/// it's still building/starting. This client classifies failures
/// ([GradioErrorType]) so callers (TtsService) can retry cold-starts and
/// rate limits automatically instead of surfacing a raw, unhelpful
/// exception on the very first hiccup.
class GradioClient {
  GradioClient(this.spaceBaseUrl);

  final String spaceBaseUrl;
  // Reused across calls — this object lives for the app's lifetime (see
  // TtsService's _wazobiaClient/_yarnGptClient), so one persistent client
  // is correct here. The previous version called `http.Client()` fresh
  // inside every request and never closed it — a real connection-pool
  // leak on every single TTS chunk generated.
  final http.Client _client = http.Client();

  static const _startTimeout = Duration(seconds: 25);
  // Generation itself (the SSE stream) can legitimately take a while on a
  // cold GPU Space — this is deliberately generous, not a bug.
  static const _streamTimeout = Duration(seconds: 120);

  Future<List<dynamic>> call({
    required String apiName,
    required List<dynamic> data,
  }) async {
    final callUri = Uri.parse('$spaceBaseUrl/gradio_api/call/$apiName');

    late final http.Response postResponse;
    try {
      postResponse = await http
          .post(
            callUri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'data': data}),
          )
          .timeout(_startTimeout);
    } on TimeoutException {
      throw GradioClientException(
        'Timed out starting Space call ($apiName) after ${_startTimeout.inSeconds}s — '
        'likely a cold/sleeping Space taking longer than usual to wake up.',
        type: GradioErrorType.timeout,
      );
    } on SocketException catch (e) {
      throw GradioClientException(
        'Network error starting Space call ($apiName): $e',
        type: GradioErrorType.network,
      );
    }

    if (postResponse.statusCode != 200) {
      throw GradioClientException(
        'Failed to start Space call ($apiName): '
        '${postResponse.statusCode} ${postResponse.body}',
        type: _classifyStatusCode(postResponse.statusCode, postResponse.body),
        statusCode: postResponse.statusCode,
      );
    }

    final eventId = jsonDecode(postResponse.body)['event_id'] as String?;
    if (eventId == null) {
      throw GradioClientException(
        'No event_id returned from $apiName — response was: ${postResponse.body}',
        type: GradioErrorType.unknown,
      );
    }

    final resultUri = Uri.parse('$spaceBaseUrl/gradio_api/call/$apiName/$eventId');
    final request = http.Request('GET', resultUri);

    late final String responseBody;
    try {
      final streamedResponse = await _client.send(request).timeout(_startTimeout);
      responseBody = await streamedResponse.stream.bytesToString().timeout(_streamTimeout);
    } on TimeoutException {
      throw GradioClientException(
        'Timed out waiting for $apiName to finish generating after '
        '${_streamTimeout.inSeconds}s — Space may be cold-starting or overloaded.',
        type: GradioErrorType.timeout,
      );
    } on SocketException catch (e) {
      throw GradioClientException('Network error streaming $apiName result: $e', type: GradioErrorType.network);
    }

    // Server-sent events look like either:
    //   event: complete
    //   data: [<result0>, <result1>, ...]
    // or, on failure:
    //   event: error
    //   data: "<error message>"
    final lines = responseBody.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('event: complete') && i + 1 < lines.length) {
        final dataLine = lines[i + 1];
        if (dataLine.startsWith('data: ')) {
          return jsonDecode(dataLine.substring('data: '.length)) as List<dynamic>;
        }
      }
      if (lines[i].startsWith('event: error') && i + 1 < lines.length) {
        final dataLine = lines[i + 1];
        final errorText = dataLine.startsWith('data: ') ? dataLine.substring('data: '.length) : dataLine;
        throw GradioClientException(
          '$apiName reported an error: $errorText',
          type: _classifyErrorText(errorText),
        );
      }
    }

    throw GradioClientException(
      'Could not parse a "complete" or "error" event from $apiName response: $responseBody',
      type: GradioErrorType.unknown,
    );
  }

  GradioErrorType _classifyStatusCode(int status, String body) {
    if (status == 429) return GradioErrorType.rateLimited;
    if (status == 503 || _looksLikeColdStart(body)) return GradioErrorType.spaceStarting;
    if (status >= 500) return GradioErrorType.serverError;
    return GradioErrorType.unknown;
  }

  GradioErrorType _classifyErrorText(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('rate limit') || lower.contains('too many requests')) return GradioErrorType.rateLimited;
    if (_looksLikeColdStart(lower)) return GradioErrorType.spaceStarting;
    return GradioErrorType.serverError;
  }

  bool _looksLikeColdStart(String text) {
    final lower = text.toLowerCase();
    return lower.contains('starting') ||
        lower.contains('building') ||
        lower.contains('sleeping') ||
        lower.contains('waking') ||
        lower.contains('not running') ||
        lower.contains('paused');
  }
}

enum GradioErrorType {
  /// Space is asleep/cold-starting/still building — usually resolves on
  /// retry after a short wait.
  spaceStarting,

  /// Too many requests, either the Space's own queue limit or the
  /// underlying model's rate limit — resolves on retry after backoff.
  rateLimited,

  /// Request or stream took longer than the configured timeout — could be
  /// a slow cold-start or a genuinely stuck Space; worth one retry, not
  /// worth retrying indefinitely.
  timeout,

  /// DNS/connection-level failure — usually a real connectivity problem,
  /// not something retrying immediately fixes, but transient blips do
  /// happen.
  network,

  /// Space responded with a 5xx that isn't a recognized cold-start state.
  serverError,

  /// Anything that doesn't fit the above — unexpected response shape, etc.
  unknown,
}

class GradioClientException implements Exception {
  GradioClientException(this.message, {this.type = GradioErrorType.unknown, this.statusCode});
  final String message;
  final GradioErrorType type;
  final int? statusCode;

  /// Whether retrying this specific failure is likely to help — network
  /// blips, cold starts, rate limits, and timeouts usually resolve; a
  /// generic server error or unknown shape usually won't.
  bool get isRetryable => type != GradioErrorType.unknown;

  @override
  String toString() => 'GradioClientException(${type.name}): $message';
}
