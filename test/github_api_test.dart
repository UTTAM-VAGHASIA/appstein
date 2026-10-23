import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/src/github_api.dart';

/// One request the stand-in GitHub received.
typedef Seen = ({String method, String path, String? auth, String body});

/// An answer that holds the request open and never answers.
const hang = 'hang';

/// An answer that closes the connection in the middle of the request.
const drop = 'drop';

/// A stand-in GitHub on loopback TCP (127.0.0.1, a free port) that answers
/// each request with the next of its scripted answers: `(status, body)`,
/// `(status, body, headers)`, [hang] or [drop].
final class StandIn {
  StandIn._(this._server);

  static Future<StandIn> start(List<Object> answers) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final standIn = StandIn._(server).._answers.addAll(answers);
    server.listen(standIn._answer);
    return standIn;
  }

  final HttpServer _server;
  final _answers = <Object>[];

  /// The requests received, in order.
  final seen = <Seen>[];

  /// The URL to give [HttpGitHubApi.apiUrl].
  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> _answer(HttpRequest request) async {
    seen.add((
      method: request.method,
      path: request.uri.toString(),
      auth: request.headers.value('authorization'),
      body: await utf8.decoder.bind(request).join(),
    ));
    final answer = _answers.isEmpty
        ? (500, {'message': 'no answer scripted'})
        : _answers.removeAt(0);
    if (answer == hang) return; // the server's close ends it
    final (
      int status,
      Object? body,
      Map<String, String> headers,
    ) = switch (answer) {
      drop => (-1, null, const {}),
      (final int s, final Object? b) => (s, b, const {}),
      (final int s, final Object? b, final Map<String, String> h) => (s, b, h),
      _ => throw ArgumentError('unknown answer $answer'),
    };
    if (status < 0) {
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.destroy();
      return;
    }
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.json;
    headers.forEach(request.response.headers.set);
    request.response.write(body == null ? '' : jsonEncode(body));
    await request.response.close();
  }

  Future<void> stop() => _server.close(force: true);
}

void main() {
  late StandIn github;
  late HttpGitHubApi api;

  Future<void> answering(
    List<Object> answers, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    github = await StandIn.start(answers);
    api = HttpGitHubApi(
      repo: 'o/r',
      token: 'test-token',
      apiUrl: github.url,
      timeout: timeout,
      retryPause: const Duration(milliseconds: 10),
    );
  }

  tearDown(() async {
    api.close();
    await github.stop();
  });

  Map<String, Object?> job(int id) => {'id': id, 'name': 'job $id'};

  test('reads every page of jobs, with the token as a bearer', () async {
    await answering([
      (
        200,
        {
          'jobs': [for (var i = 0; i < 100; i++) job(i)],
        },
      ),
      (
        200,
        {
          'jobs': [job(100), job(101), job(102)],
        },
      ),
    ]);
    final jobs = await api.jobsOfAttempt(5, 2);
    expect(jobs, hasLength(103));
    expect(
      [for (final s in github.seen) s.path],
      [
        '/repos/o/r/actions/runs/5/attempts/2/jobs?per_page=100&page=1',
        '/repos/o/r/actions/runs/5/attempts/2/jobs?per_page=100&page=2',
      ],
    );
    expect(github.seen.first.auth, 'Bearer test-token');
  });

  test('a server error on a read is tried again', () async {
    await answering([
      (502, {'message': 'Bad Gateway'}),
      (503, {'message': 'Unavailable'}),
      (
        200,
        [
          {'message': 'The hosted runner lost communication with the server.'},
        ],
      ),
    ]);
    final notes = await api.annotations(7);
    expect(notes, hasLength(1));
    expect(github.seen, hasLength(3));
  });

  test('a read that gets no answer in time is tried again', () async {
    await answering([
      hang,
      (200, const <Object?>[]),
    ], timeout: const Duration(milliseconds: 300));
    expect(await api.annotations(7), isEmpty);
    expect(github.seen, hasLength(2));
  });

  test('a read whose connection drops is tried again', () async {
    await answering([drop, (200, const <Object?>[])]);
    expect(await api.annotations(7), isEmpty);
    expect(github.seen, hasLength(2));
  });

  group('rate limits', () {
    Future<GitHubApiException> refusal(
      (int, Object?, Map<String, String>) a,
    ) async {
      await answering([a]);
      try {
        await api.postStatus(
          'abc',
          state: 'pending',
          context: 'c',
          description: 'd',
          targetUrl: 'u',
        );
      } on GitHubApiException catch (error) {
        return error;
      }
      fail('the post did not fail');
    }

    // Each signal alone: the messages of the header cases don't say
    // "rate limit".
    test('a 403 with retry-after is a rate limit', () async {
      final error = await refusal((
        403,
        {'message': 'Forbidden'},
        {'retry-after': '60'},
      ));
      expect(error.statusCode, 403);
      expect(error.rateLimited, isTrue);
    });

    test('a 403 with no requests remaining is a rate limit', () async {
      final error = await refusal((
        403,
        {'message': 'Forbidden'},
        {'x-ratelimit-remaining': '0'},
      ));
      expect(error.rateLimited, isTrue);
    });

    test('a 403 whose message is about a rate limit is one', () async {
      final error = await refusal((
        403,
        {'message': 'You have exceeded a secondary rate limit.'},
        const {},
      ));
      expect(error.rateLimited, isTrue);
    });

    test('a 429 is a rate limit', () async {
      final error = await refusal((429, {'message': 'Too Many'}, const {}));
      expect(error.rateLimited, isTrue);
    });

    test('a plain 403 is not', () async {
      final error = await refusal((
        403,
        {'message': 'Resource not accessible by integration'},
        {'x-ratelimit-remaining': '4999'},
      ));
      expect(error.rateLimited, isFalse);
    });
  });

  test('a read gives up after three tries', () async {
    await answering([
      (500, {'message': 'one'}),
      (500, {'message': 'two'}),
      (500, {'message': 'three'}),
      (200, const <Object?>[]),
    ]);
    await expectLater(
      api.statusesPage('abc', 1),
      throwsA(
        isA<GitHubApiException>()
            .having((e) => e.statusCode, 'statusCode', 500)
            .having((e) => e.message, 'message', 'three'),
      ),
    );
    expect(github.seen, hasLength(3));
  });

  test('a refused read is not tried again', () async {
    await answering([
      (403, {'message': 'Resource not accessible by integration'}),
      (200, const <Object?>[]),
    ]);
    await expectLater(
      api.statusesPage('abc', 1),
      throwsA(
        isA<GitHubApiException>().having(
          (e) => '$e',
          'text',
          'HTTP 403 Resource not accessible by integration',
        ),
      ),
    );
    expect(github.seen, hasLength(1));
  });

  test('a write is never tried again', () async {
    await answering([
      (502, {'message': 'Bad Gateway'}),
      (201, const <String, Object?>{}),
    ]);
    await expectLater(api.rerunJob(9), throwsA(isA<GitHubApiException>()));
    expect(
      [for (final s in github.seen) '${s.method} ${s.path}'],
      ['POST /repos/o/r/actions/jobs/9/rerun'],
    );
  });

  test('a status is posted with its four fields', () async {
    await answering([(201, const <String, Object?>{})]);
    await api.postStatus(
      'abc',
      state: 'pending',
      context: 'CI trace / test (ubuntu-latest)',
      description: 'a1 10:00:00 UTC, starting test',
      targetUrl: 'https://github.com/o/r/actions/runs/1/attempts/1',
    );
    expect(github.seen.single.path, '/repos/o/r/statuses/abc');
    expect(jsonDecode(github.seen.single.body), {
      'state': 'pending',
      'context': 'CI trace / test (ubuntu-latest)',
      'description': 'a1 10:00:00 UTC, starting test',
      'target_url': 'https://github.com/o/r/actions/runs/1/attempts/1',
    });
  });
}
