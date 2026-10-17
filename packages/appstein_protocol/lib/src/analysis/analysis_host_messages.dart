import '../json_fields.dart';
import 'code_reading.dart';

// What crosses the connection to a project's analysis host (decision record
// 0002): one JSON object per line, each way. A client sends an
// [AnalysisHostHello] first, the host answers it with an
// [AnalysisHostWelcome], and then the client asks [AnalysisHostQuestion]s,
// one at a time, each answered by one [AnalysisHostAnswer].

/// What a project's analysis host writes in its address file: how a client
/// reaches it. The file is named by a hash of the project's path, in a
/// folder only its user can read, and written whole.
final class AnalysisHostAddress {
  /// Creates an address.
  const AnalysisHostAddress({
    required this.port,
    required this.secret,
    required this.processId,
    required this.appsteinVersion,
  });

  /// Reads an address written by [toJson]. Throws a [FormatException] when
  /// [map] isn't one.
  factory AnalysisHostAddress.fromJson(Map<String, Object?> map) {
    final json = JsonFields('the analysis host address file', map);
    return AnalysisHostAddress(
      port: json.integer('port'),
      secret: json.string('secret'),
      processId: json.integer('processId'),
      appsteinVersion: json.string('appsteinVersion'),
    );
  }

  /// The port the host listens on, on `127.0.0.1`.
  final int port;

  /// The secret a client sends first: every local program can reach a
  /// loopback port, and only the user's own processes can read this.
  final String secret;

  /// The host's process ID.
  final int processId;

  /// The Appstein version the host runs.
  final String appsteinVersion;

  /// The address as JSON, as the address file holds it.
  Map<String, Object?> toJson() => {
    'port': port,
    'secret': secret,
    'processId': processId,
    'appsteinVersion': appsteinVersion,
  };
}

/// The first line a client sends: the secret, and its Appstein version. The
/// host closes a connection whose first line isn't this with its secret.
final class AnalysisHostHello {
  /// Creates the hello.
  const AnalysisHostHello({
    required this.secret,
    required this.appsteinVersion,
  });

  /// Reads a hello written by [toJson]. Throws a [FormatException] when
  /// [map] isn't one.
  factory AnalysisHostHello.fromJson(Map<String, Object?> map) {
    final json = JsonFields(_source, map);
    return AnalysisHostHello(
      secret: json.string('secret'),
      appsteinVersion: json.string('appsteinVersion'),
    );
  }

  /// The secret of the host's address file.
  final String secret;

  /// The client's Appstein version.
  final String appsteinVersion;

  /// The hello as JSON.
  Map<String, Object?> toJson() => {
    'secret': secret,
    'appsteinVersion': appsteinVersion,
  };
}

/// The host's answer to a hello with its secret: the connection is open.
final class AnalysisHostWelcome {
  /// Creates the welcome.
  const AnalysisHostWelcome({
    required this.appsteinVersion,
    required this.processId,
  });

  /// Reads a welcome written by [toJson]. Throws a [FormatException] when
  /// [map] isn't one.
  factory AnalysisHostWelcome.fromJson(Map<String, Object?> map) {
    final json = JsonFields(_source, map);
    return AnalysisHostWelcome(
      appsteinVersion: json.string('appsteinVersion'),
      processId: json.integer('processId'),
    );
  }

  /// The host's Appstein version.
  final String appsteinVersion;

  /// The host's process ID.
  final int processId;

  /// The welcome as JSON.
  Map<String, Object?> toJson() => {
    'appsteinVersion': appsteinVersion,
    'processId': processId,
  };
}

/// Which question of the engine's `CodeAnalysis` interface a client asks.
enum AnalysisHostQuestionKind {
  /// `read`: what the analyzer says about the project as its files are now.
  read,

  /// `canDartFix`: whether `dart fix` can migrate one diagnostic.
  canDartFix,

  /// `formatChanges`: which files the formatter would change.
  formatChanges,

  /// `pendingFixes`: the fixes `dart fix --dry-run` would list.
  pendingFixes,

  /// `applyFixesAndFormat`: rewrite the project as `dart fix --apply` and
  /// `dart format` would.
  applyFixesAndFormat,
}

/// One question to the analysis host: one call of the engine's
/// `CodeAnalysis`, with its arguments.
final class AnalysisHostQuestion {
  /// Creates a question.
  const AnalysisHostQuestion({
    required this.id,
    required this.kind,
    this.within,
    this.diagnostic,
    this.files = const [],
    this.leaveUnformatted = const [],
  });

  /// Reads a question written by [toJson]. Throws a [FormatException] when
  /// [map] isn't one.
  factory AnalysisHostQuestion.fromJson(Map<String, Object?> map) {
    final json = JsonFields(_source, map);
    final kindName = json.string('kind');
    final within = json.optionalInteger('withinMs');
    return AnalysisHostQuestion(
      id: json.integer('id'),
      kind: AnalysisHostQuestionKind.values.firstWhere(
        (kind) => kind.name == kindName,
        orElse: () => throw FormatException('$_source: no question $kindName.'),
      ),
      within: within == null ? null : Duration(milliseconds: within),
      diagnostic: switch (json.optionalObject('diagnostic')) {
        null => null,
        final diagnostic => CodeDiagnostic.fromJson(diagnostic.json),
      },
      files: map.containsKey('files') ? json.strings('files') : const [],
      leaveUnformatted: map.containsKey('leaveUnformatted')
          ? json.strings('leaveUnformatted')
          : const [],
    );
  }

  /// Which answer belongs to it: the same number.
  final int id;

  /// Which question it is.
  final AnalysisHostQuestionKind kind;

  /// The question's `within`; null for [AnalysisHostQuestionKind.read].
  final Duration? within;

  /// The diagnostic of [AnalysisHostQuestionKind.canDartFix].
  final CodeDiagnostic? diagnostic;

  /// The files of [AnalysisHostQuestionKind.formatChanges].
  final List<String> files;

  /// For [AnalysisHostQuestionKind.applyFixesAndFormat]: each file of the
  /// last reading that must not be formatted (a generated file). The client
  /// asks its own `leaveUnformatted` about every file of that reading before
  /// it sends the question, since the host can't call back into it.
  final List<String> leaveUnformatted;

  /// The question as JSON.
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    if (within case final within?) 'withinMs': within.inMilliseconds,
    if (diagnostic case final diagnostic?) 'diagnostic': diagnostic.toJson(),
    if (files.isNotEmpty) 'files': files,
    if (leaveUnformatted.isNotEmpty) 'leaveUnformatted': leaveUnformatted,
  };
}

/// The host's answer to one [AnalysisHostQuestion]: the value the engine's
/// `CodeAnalysis` returned, as JSON, or why it could not answer.
final class AnalysisHostAnswer {
  /// The question was answered with [value]: the JSON of the answer
  /// ([CodeReading], [FormatAnswers], [PendingFixes], [AppliedChanges]), or
  /// a `bool` for [AnalysisHostQuestionKind.canDartFix].
  const AnalysisHostAnswer.answered(this.id, Object this.value)
    : failure = null,
      refusalCode = null,
      timedOut = false;

  /// The analysis could not answer: the reason of the engine's
  /// `CodeAnalysisException`, and its refusal code.
  const AnalysisHostAnswer.failed(
    this.id,
    String this.failure, {
    this.refusalCode,
  }) : value = null,
       timedOut = false;

  /// The question's `within` ran out (a `TimeoutException`).
  const AnalysisHostAnswer.timedOut(this.id)
    : value = null,
      failure = null,
      refusalCode = null,
      timedOut = true;

  /// Reads an answer written by [toJson]. Throws a [FormatException] when
  /// [map] isn't one.
  factory AnalysisHostAnswer.fromJson(Map<String, Object?> map) {
    final json = JsonFields(_source, map);
    final id = json.integer('id');
    if (json.optionalString('failure') case final failure?) {
      return AnalysisHostAnswer.failed(
        id,
        failure,
        refusalCode: json.optionalString('refusalCode'),
      );
    }
    if (map['timedOut'] == true) return AnalysisHostAnswer.timedOut(id);
    return switch (map['value']) {
      final Object value => AnalysisHostAnswer.answered(id, value),
      null => throw const FormatException('$_source: an answer has no value.'),
    };
  }

  /// The number of the question it answers.
  final int id;

  /// The answer, as JSON; null when it failed or timed out.
  final Object? value;

  /// Why the analysis could not answer; null when it did.
  final String? failure;

  /// The server's own code for the refusal, when it gave one.
  final String? refusalCode;

  /// Whether the question's `within` ran out.
  final bool timedOut;

  /// The answer as JSON.
  Map<String, Object?> toJson() => {
    'id': id,
    'value': ?value,
    'failure': ?failure,
    'refusalCode': ?refusalCode,
    if (timedOut) 'timedOut': true,
  };
}

/// What the host sends when a question leaves its queue and the server
/// begins on it: the question's own time limit starts here for the client,
/// since the wait in the queue is the questions ahead's, each with a limit
/// of its own.
final class AnalysisHostTurn {
  /// Creates the line for the question [id].
  const AnalysisHostTurn(this.id);

  /// The question whose turn began.
  final int id;

  /// Whether [map] is a turn line (and not an answer).
  static bool isTurn(Map<String, Object?> map) => map['turn'] == true;

  /// The line as JSON.
  Map<String, Object?> toJson() => {'id': id, 'turn': true};
}

const _source = 'a message of the analysis host';
