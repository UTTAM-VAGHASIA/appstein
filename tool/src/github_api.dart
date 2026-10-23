/// The few GitHub REST calls the lost-job tools make (ticket 15 of slice
/// 1d.7), behind an interface so their tests run on recorded answers.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The GitHub REST calls of `tool/ci_lost_jobs.dart` and
/// `tool/ci_unit_tests.dart`, for one repository.
abstract interface class GitHubApi {
  /// The jobs of attempt [attempt] of run [runId], every page
  /// (`GET …/actions/runs/{id}/attempts/{n}/jobs`; Actions: read).
  Future<List<Map<String, Object?>>> jobsOfAttempt(int runId, int attempt);

  /// The annotations of job [jobId]'s check run
  /// (`GET …/check-runs/{id}/annotations`; Checks: read).
  Future<List<Object?>> annotations(int jobId);

  /// Page [page] (from 1) of the commit statuses of [sha], newest first,
  /// 100 to a page (`GET …/commits/{sha}/statuses`).
  Future<List<Map<String, Object?>>> statusesPage(String sha, int page);

  /// Sets a commit status on [sha] (`POST …/statuses/{sha}`; Commit
  /// statuses: write).
  Future<void> postStatus(
    String sha, {
    required String state,
    required String context,
    required String description,
    required String targetUrl,
  });

  /// Reruns job [jobId] and the jobs that depend on it
  /// (`POST …/actions/jobs/{id}/rerun`; Actions: write).
  Future<void> rerunJob(int jobId);

  /// Reruns every failed job of run [runId]
  /// (`POST …/actions/runs/{id}/rerun-failed-jobs`; Actions: write).
  Future<void> rerunFailedJobs(int runId);
}

/// A call GitHub answered with an error, or that got no answer.
final class GitHubApiException implements Exception {
  /// An error with GitHub's HTTP [statusCode] (0 when there was no answer)
  /// and [message]; [rateLimited] when GitHub said to slow down.
  const GitHubApiException(
    this.statusCode,
    this.message, {
    this.rateLimited = false,
  });

  /// The HTTP status, or 0 when the call got no answer.
  final int statusCode;

  /// Whether this is GitHub's rate limit: a 429, or a 403 with a
  /// `retry-after` header, `x-ratelimit-remaining: 0` or a message about a
  /// rate limit. It passes; other 403s mean the token may not do this.
  final bool rateLimited;

  /// GitHub's `message`, or what went wrong. Never a header.
  final String message;

  @override
  String toString() => statusCode == 0 ? message : 'HTTP $statusCode $message';
}

/// [GitHubApi] over HTTPS with `dart:io`'s [HttpClient].
final class HttpGitHubApi implements GitHubApi {
  /// Calls for [repo] (`owner/name`) with [token]. Each call gives up after
  /// [timeout].
  HttpGitHubApi({
    required this.repo,
    required this._token,
    this.apiUrl = 'https://api.github.com',
    this.timeout = const Duration(seconds: 30),
    this.retryPause = const Duration(seconds: 2),
  });

  /// The repository, `owner/name`.
  final String repo;

  /// The API's root URL. The tools use the default; the tests point it at
  /// a stand-in server on loopback.
  final String apiUrl;

  /// How long one call may take.
  final Duration timeout;

  /// The pause before a read is tried again.
  final Duration retryPause;

  final String _token;
  final _client = HttpClient();

  /// Ends the client's connections.
  void close() => _client.close(force: true);

  /// How many times a read is tried in all, when GitHub gives no answer,
  /// the connection fails, or it answers with a server error (5xx). A write
  /// is tried once: a rerun asked twice would start two attempts.
  static const readTries = 3;

  Future<Object?> _call(String method, String path, [Object? body]) async {
    for (var tried = 1; ; tried++) {
      try {
        return await _once(method, path, body);
      } on GitHubApiException catch (error) {
        final transient = error.statusCode == 0 || error.statusCode >= 500;
        if (method != 'GET' || !transient || tried >= readTries) rethrow;
        await Future<void>.delayed(retryPause);
      }
    }
  }

  Future<Object?> _once(String method, String path, Object? body) async {
    try {
      return await _send(method, path, body).timeout(timeout);
    } on TimeoutException {
      throw GitHubApiException(
        0,
        'GitHub gave no answer within ${timeout.inSeconds} s',
      );
    } on IOException catch (error) {
      throw GitHubApiException(0, 'The call failed: ${error.runtimeType}');
    }
  }

  Future<Object?> _send(String method, String path, Object? body) async {
    final request = await _client.openUrl(method, Uri.parse('$apiUrl$path'));
    request.headers
      ..set('Accept', 'application/vnd.github+json')
      ..set('X-GitHub-Api-Version', '2022-11-28')
      ..set('User-Agent', 'appstein-ci')
      ..set('Authorization', 'Bearer $_token');
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(body));
    }
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    Object? data;
    try {
      data = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      data = null;
    }
    if (response.statusCode >= 300) {
      final message = data is Map<String, Object?> && data['message'] is String
          ? data['message']! as String
          : 'no message';
      final status = response.statusCode;
      final headers = response.headers;
      throw GitHubApiException(
        status,
        message,
        rateLimited:
            status == 429 ||
            (status == 403 &&
                (headers.value('retry-after') != null ||
                    headers.value('x-ratelimit-remaining') == '0' ||
                    message.toLowerCase().contains('rate limit'))),
      );
    }
    return data;
  }

  @override
  Future<List<Map<String, Object?>>> jobsOfAttempt(
    int runId,
    int attempt,
  ) async {
    final jobs = <Map<String, Object?>>[];
    for (var page = 1; ; page++) {
      final data = await _call(
        'GET',
        '/repos/$repo/actions/runs/$runId/attempts/$attempt/jobs'
            '?per_page=100&page=$page',
      );
      final list = data is Map<String, Object?> ? data['jobs'] : null;
      if (list is! List<Object?>) break;
      jobs.addAll(list.whereType<Map<String, Object?>>());
      if (list.length < 100) break;
    }
    return jobs;
  }

  @override
  Future<List<Object?>> annotations(int jobId) async {
    final data = await _call(
      'GET',
      '/repos/$repo/check-runs/$jobId/annotations?per_page=100',
    );
    return data is List<Object?> ? data : const [];
  }

  @override
  Future<List<Map<String, Object?>>> statusesPage(String sha, int page) async {
    final data = await _call(
      'GET',
      '/repos/$repo/commits/$sha/statuses?per_page=100&page=$page',
    );
    return data is List<Object?>
        ? data.whereType<Map<String, Object?>>().toList()
        : const [];
  }

  @override
  Future<void> postStatus(
    String sha, {
    required String state,
    required String context,
    required String description,
    required String targetUrl,
  }) async {
    await _call('POST', '/repos/$repo/statuses/$sha', {
      'state': state,
      'context': context,
      'description': description,
      'target_url': targetUrl,
    });
  }

  @override
  Future<void> rerunJob(int jobId) async {
    await _call('POST', '/repos/$repo/actions/jobs/$jobId/rerun');
  }

  @override
  Future<void> rerunFailedJobs(int runId) async {
    await _call('POST', '/repos/$repo/actions/runs/$runId/rerun-failed-jobs');
  }
}
