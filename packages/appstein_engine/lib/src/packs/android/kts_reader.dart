/// Reads Gradle's Kotlin build scripts (`.gradle.kts`) far enough to find
/// plain settings (spec §6.5).
///
/// It is not a Kotlin parser. It knows strings (with `$` templates),
/// comments (nested `/* */` too), numbers and brackets; follows
/// `name { … }` blocks; and records each assignment, call statement and
/// block with the path of blocks it is in. The contents of anything it
/// doesn't follow (an `if`, `when`, loop or `try`, or a lambda passed to a
/// call) are read under a [ktsOpaque] segment, so a value set there is
/// seen and can be reported as conditional, never missed. A value that
/// isn't a plain literal or name is kept as [KtsComputed], never evaluated.
library;

/// The path segment of a block Appstein doesn't follow.
const ktsOpaque = '?';

/// The value on the right of `=`, as written.
sealed class KtsValue {
  const KtsValue(this.text);

  /// The value's text, with its spacing normalized.
  final String text;
}

/// A string literal without `$` templates, such as `"dev.sample.app"`.
final class KtsString extends KtsValue {
  /// Creates the value.
  const KtsString(this.value, super.text);

  /// The string, with its escapes decoded.
  final String value;
}

/// An integer literal, such as `36`.
final class KtsInt extends KtsValue {
  /// Creates the value.
  const KtsInt(this.value, super.text);

  /// The number.
  final int value;
}

/// `true` or `false`.
final class KtsBool extends KtsValue {
  /// Creates the value.
  const KtsBool(this.value, super.text);

  /// The boolean.
  final bool value;
}

/// A name, or names joined by dots, such as `flutter.minSdkVersion` or
/// `JavaVersion.VERSION_17`.
final class KtsName extends KtsValue {
  /// Creates the value.
  const KtsName(super.text);
}

/// A call with one string argument, such as
/// `signingConfigs.getByName("debug")`.
final class KtsCallValue extends KtsValue {
  /// Creates the value.
  const KtsCallValue(this.name, this.argument, super.text);

  /// The called name, such as `signingConfigs.getByName`.
  final String name;

  /// The argument, such as `debug`.
  final String argument;
}

/// Anything else: computed when Gradle runs. Never evaluated.
final class KtsComputed extends KtsValue {
  /// Creates the value.
  const KtsComputed(super.text);
}

/// `a.b = value` (or `+=`, `-=`).
final class KtsAssignment {
  /// Creates the assignment.
  const KtsAssignment({
    required this.path,
    required this.value,
    required this.line,
  });

  /// The blocks it is in, then the parts of the assigned name:
  /// `android { defaultConfig { minSdk = 24 } }` and
  /// `android.defaultConfig.minSdk = 24` both give
  /// `[android, defaultConfig, minSdk]`.
  final List<String> path;

  /// The assigned value.
  final KtsValue value;

  /// Its 1-based line.
  final int line;

  /// Whether it is inside a block Appstein doesn't follow.
  bool get conditional => path.contains(ktsOpaque);

  /// [path] without its [ktsOpaque] segments.
  List<String> get plainPath => [
    for (final segment in path)
      if (segment != ktsOpaque) segment,
  ];
}

/// A call statement, such as
/// `id("com.android.application") version "9.1.0" apply false` or
/// `minSdkVersion(21)`.
final class KtsCall {
  /// Creates the call.
  const KtsCall({
    required this.path,
    required this.name,
    required this.arguments,
    required this.argument,
    required this.infix,
    required this.line,
  });

  /// The blocks it is in, then the parts of its name before the last.
  final List<String> path;

  /// The last part of its name, such as `id`.
  final String name;

  /// The text between its parentheses.
  final String arguments;

  /// Its argument, when there is exactly one and it is a string without
  /// templates, a number, `true`/`false` or a name; else null.
  final KtsValue? argument;

  /// The words after the parentheses and their values, such as `version`
  /// to `"9.1.0"` and `apply` to `false`.
  final Map<String, KtsValue> infix;

  /// Its 1-based line.
  final int line;

  /// Whether it is inside a block Appstein doesn't follow.
  bool get conditional => path.contains(ktsOpaque);

  /// [path] without its [ktsOpaque] segments.
  List<String> get plainPath => [
    for (final segment in path)
      if (segment != ktsOpaque) segment,
  ];
}

/// A `name { … }` block, or a container entry such as
/// `create("dev") { … }`.
final class KtsBlock {
  /// Creates the block.
  const KtsBlock({required this.path, required this.line});

  /// The blocks it is in, then its own name: `dev` for `create("dev")`,
  /// or [ktsOpaque] when Appstein doesn't follow it.
  final List<String> path;

  /// The 1-based line it starts on.
  final int line;
}

/// Whether the paths [a] and [b] are the same.
bool ktsPathIs(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _endsWith(List<String> list, List<String> suffix) {
  if (list.length < suffix.length) return false;
  final offset = list.length - suffix.length;
  for (var i = 0; i < suffix.length; i++) {
    if (list[offset + i] != suffix[i]) return false;
  }
  return true;
}

List<String> _plain(List<String> path) => [
  for (final segment in path)
    if (segment != ktsOpaque) segment,
];

/// What [readKts] found in a script.
final class KtsScript {
  /// Creates the result.
  const KtsScript({
    required this.assignments,
    required this.calls,
    required this.blocks,
  });

  /// Every assignment, in file order.
  final List<KtsAssignment> assignments;

  /// Every call statement, in file order.
  final List<KtsCall> calls;

  /// Every block, in file order.
  final List<KtsBlock> blocks;

  /// Every assignment to [path], such as
  /// `['android', 'defaultConfig', 'minSdk']`: the ones whose
  /// [KtsAssignment.plainPath] ends with it. A plain setting is exactly at
  /// [path] ([ktsPathIs]); the others are inside an `if`, a lambda, or a
  /// block such as `afterEvaluate { }`.
  List<KtsAssignment> assignmentsTo(List<String> path) => [
    for (final assignment in assignments)
      if (_endsWith(assignment.plainPath, path)) assignment,
  ];

  /// Every call named [name] in the blocks of [path], found the same way
  /// as [assignmentsTo].
  List<KtsCall> callsTo(List<String> path, String name) => [
    for (final call in calls)
      if (call.name == name && _endsWith(call.plainPath, path)) call,
  ];

  /// The blocks directly inside [path], [ktsOpaque] ones included (a
  /// container entry with a computed name, such as `create(name) { }`).
  ///
  /// A block that is in [path] only through an `if`, a lambda, a scope
  /// function or a block such as `afterEvaluate { }` (found the way
  /// [assignmentsTo] finds assignments) is returned as a [ktsOpaque] entry,
  /// so a caller sees that something is declared there that it can't name.
  List<KtsBlock> blocksIn(List<String> path) => [
    for (final block in blocks)
      if (block.path.length == path.length + 1 &&
          ktsPathIs(block.path.sublist(0, path.length), path))
        block
      else if (path.isNotEmpty &&
          _endsWith(_plain(block.path.sublist(0, block.path.length - 1)), path))
        KtsBlock(path: [...path, ktsOpaque], line: block.line),
  ];
}

/// A script Appstein can't read: a string, comment or bracket that is
/// never closed, or a bracket that closes nothing.
final class KtsFormatException implements Exception {
  /// Creates the exception.
  const KtsFormatException(this.message, this.line);

  /// What is wrong.
  final String message;

  /// The 1-based line where it starts.
  final int line;

  @override
  String toString() => 'line $line: $message';
}

/// Reads [text], a Gradle Kotlin script.
///
/// Throws a [KtsFormatException] when a string, comment or bracket is
/// never closed, or a bracket closes nothing.
KtsScript readKts(String text) {
  final parser = _Parser(_Tokenizer(text).run())..body(const []);
  return KtsScript(
    assignments: List.unmodifiable(parser.assignments),
    calls: List.unmodifiable(parser.calls),
    blocks: List.unmodifiable(parser.blocks),
  );
}

enum _Kind { name, string, number, symbol, newline, end }

final class _Token {
  const _Token(this.kind, this.text, this.line, {this.value});

  final _Kind kind;
  final String text;
  final int line;

  /// A string's decoded value; null for a string with templates, a
  /// character literal, or any other token.
  final String? value;

  bool isSymbol(String symbol) => kind == _Kind.symbol && text == symbol;

  bool isName(String name) => kind == _Kind.name && text == name;
}

const _twoCharSymbols = {
  '==', '!=', '<=', '>=', '&&', '||', '->', '?.', '?:', '::', //
  '+=', '-=', '*=', '/=', '%=', '..', '++', '--', '!!',
};

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

bool _isNameStart(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F;

bool _isNamePart(int c) => _isNameStart(c) || _isDigit(c);

final class _Tokenizer {
  _Tokenizer(this.source);

  final String source;
  final _tokens = <_Token>[];
  var _i = 0;
  var _line = 1;

  List<_Token> run() {
    while (_i < source.length) {
      final c = source.codeUnitAt(_i);
      if (c == 0x0A) {
        _tokens.add(_Token(_Kind.newline, '\n', _line));
        _line++;
        _i++;
      } else if (c == 0x20 || c == 0x09 || c == 0x0D || c == 0x0C) {
        _i++;
      } else if (source.startsWith('//', _i)) {
        while (_i < source.length && source.codeUnitAt(_i) != 0x0A) {
          _i++;
        }
      } else if (source.startsWith('/*', _i)) {
        _blockComment();
      } else if (c == 0x22) {
        _tokens.add(_string());
      } else if (c == 0x27) {
        _tokens.add(_char());
      } else if (c == 0x60) {
        _tokens.add(_backticked());
      } else if (_isNameStart(c)) {
        final start = _i;
        while (_i < source.length && _isNamePart(source.codeUnitAt(_i))) {
          _i++;
        }
        _tokens.add(_Token(_Kind.name, source.substring(start, _i), _line));
      } else if (_isDigit(c)) {
        _tokens.add(_number());
      } else {
        final two = _i + 1 < source.length ? source.substring(_i, _i + 2) : '';
        final text = _twoCharSymbols.contains(two) ? two : source[_i];
        _tokens.add(_Token(_Kind.symbol, text, _line));
        _i += text.length;
      }
    }
    _tokens.add(_Token(_Kind.end, '', _line));
    return _tokens;
  }

  void _blockComment() {
    final start = _line;
    var depth = 0;
    while (true) {
      if (_i >= source.length) {
        throw KtsFormatException('a comment is never closed', start);
      }
      if (source.startsWith('/*', _i)) {
        depth++;
        _i += 2;
      } else if (source.startsWith('*/', _i)) {
        depth--;
        _i += 2;
        if (depth == 0) return;
      } else {
        if (source.codeUnitAt(_i) == 0x0A) _line++;
        _i++;
      }
    }
  }

  _Token _number() {
    final start = _i;
    while (_i < source.length) {
      final c = source.codeUnitAt(_i);
      final decimalPoint =
          c == 0x2E &&
          _i + 1 < source.length &&
          _isDigit(source.codeUnitAt(_i + 1));
      if (!_isNamePart(c) && !decimalPoint) break;
      _i++;
    }
    return _Token(_Kind.number, source.substring(start, _i), _line);
  }

  _Token _char() {
    final start = _i;
    final line = _line;
    _i++;
    while (true) {
      if (_i >= source.length || source.codeUnitAt(_i) == 0x0A) {
        throw KtsFormatException('a character literal is never closed', line);
      }
      final c = source.codeUnitAt(_i);
      _i += c == 0x5C ? 2 : 1;
      if (c == 0x27) break;
    }
    return _Token(_Kind.string, source.substring(start, _i), line);
  }

  _Token _backticked() {
    final line = _line;
    final end = source.indexOf('`', _i + 1);
    if (end < 0 || source.substring(_i, end).contains('\n')) {
      throw KtsFormatException('a `name` is never closed', line);
    }
    final name = source.substring(_i + 1, end);
    _i = end + 1;
    return _Token(_Kind.name, name, line);
  }

  _Token _string() {
    final start = _i;
    final line = _line;
    final raw = source.startsWith('"""', _i);
    _i += raw ? 3 : 1;
    final value = StringBuffer();
    var template = false;
    while (true) {
      if (_i >= source.length) {
        throw KtsFormatException('a string is never closed', line);
      }
      final c = source.codeUnitAt(_i);
      if (raw && source.startsWith('"""', _i)) {
        _i += 3;
        // `"""a""""` ends with a quote that belongs to the text.
        while (_i < source.length && source.codeUnitAt(_i) == 0x22) {
          value.write('"');
          _i++;
        }
        break;
      }
      if (!raw && c == 0x22) {
        _i++;
        break;
      }
      if (c == 0x0A) {
        if (!raw) throw KtsFormatException('a string is never closed', line);
        _line++;
      } else if (!raw && c == 0x5C) {
        _escape(value, line);
        continue;
      } else if (c == 0x24 && _i + 1 < source.length) {
        final next = source.codeUnitAt(_i + 1);
        if (next == 0x7B) {
          template = true;
          _i += 2;
          _templateBody(line);
          continue;
        }
        if (_isNameStart(next)) {
          template = true;
          _i++;
          while (_i < source.length && _isNamePart(source.codeUnitAt(_i))) {
            _i++;
          }
          continue;
        }
      }
      value.writeCharCode(c);
      _i++;
    }
    return _Token(
      _Kind.string,
      source.substring(start, _i),
      line,
      value: template ? null : value.toString(),
    );
  }

  void _escape(StringBuffer value, int line) {
    if (_i + 1 >= source.length) {
      throw KtsFormatException('a string is never closed', line);
    }
    final escaped = source[_i + 1];
    if (escaped == 'u' && _i + 5 < source.length) {
      final code = int.tryParse(source.substring(_i + 2, _i + 6), radix: 16);
      if (code != null) {
        value.writeCharCode(code);
        _i += 6;
        return;
      }
    }
    value.write(switch (escaped) {
      'n' => '\n',
      't' => '\t',
      'r' => '\r',
      'b' => '\b',
      _ => escaped,
    });
    _i += 2;
  }

  /// Skips a `${…}` template up to its closing brace, strings inside it
  /// included.
  void _templateBody(int line) {
    var depth = 1;
    while (depth > 0) {
      if (_i >= source.length) {
        throw KtsFormatException('a string is never closed', line);
      }
      final c = source.codeUnitAt(_i);
      if (c == 0x22) {
        _string();
        continue;
      }
      if (c == 0x7B) depth++;
      if (c == 0x7D) depth--;
      if (c == 0x0A) _line++;
      _i++;
    }
  }
}

/// Calls whose trailing block is a container entry named by their string
/// argument, such as `create("dev") { … }`.
const _containerCalls = {
  'create', 'register', 'getByName', 'named', 'maybeCreate', //
};

const _controlWords = {
  'if', 'else', 'when', 'for', 'while', 'do', 'try', 'catch', 'finally', //
};

const _declarationWords = {
  'val', 'var', 'fun', 'import', 'package', 'class', 'object', //
  'interface', 'enum', 'typealias', 'return', 'throw', 'private', //
  'internal', 'public', 'protected', 'abstract', 'open', 'data', //
  'sealed', 'lateinit', 'const', 'override', 'inline',
};

/// Symbols after which a statement goes on to the next line.
const _continuesAfter = {
  '=', '.', '?.', ',', '+', '-', '*', '/', '%', '&&', '||', '?:', //
  '->', '..', '+=', '-=', '==', '!=', '<', '>', '<=', '>=', ':',
};

/// Symbols in [_continuesAfter] that also end lines without continuing
/// (`import a.*`, `List<String>`).
const _weakContinuers = {'*', '<', '>', ':'};

/// Scope and configure functions: their block runs on some other receiver,
/// so what it sets is read under [ktsOpaque].
const _scopeFunctions = {'apply', 'run', 'also', 'let', 'with', 'configure'};

/// Symbols that, starting a line, continue the statement before.
const _continuesBefore = {'.', '?.', '?:', '&&', '||'};

final class _Parser {
  _Parser(this._tokens);

  final List<_Token> _tokens;
  var _pos = 0;
  final assignments = <KtsAssignment>[];
  final calls = <KtsCall>[];
  final blocks = <KtsBlock>[];

  _Token get _peek => _tokens[_pos];

  _Token _ahead(int offset) =>
      _tokens[(_pos + offset).clamp(0, _tokens.length - 1)];

  /// Reads statements up to the `}` that closes a block opened on
  /// [openLine] (and consumes it), or to the end of the script when
  /// [openLine] is null.
  void body(List<String> path, {int? openLine}) {
    while (true) {
      final token = _peek;
      if (token.kind == _Kind.newline || token.isSymbol(';')) {
        _pos++;
      } else if (token.kind == _Kind.end) {
        if (openLine != null) {
          throw KtsFormatException('a block is never closed', openLine);
        }
        return;
      } else if (token.isSymbol('}')) {
        if (openLine == null) {
          throw KtsFormatException('a "}" closes no block', token.line);
        }
        _pos++;
        return;
      } else {
        _statement(path);
      }
    }
  }

  void _statement(List<String> path) {
    final token = _peek;
    if (token.kind == _Kind.name && _controlWords.contains(token.text)) {
      _control(path);
    } else if (token.kind == _Kind.name &&
        !_declarationWords.contains(token.text)) {
      _named(path);
    } else if (token.kind == _Kind.name &&
        (token.text == 'import' || token.text == 'package')) {
      _collect(path, lineOnly: true);
    } else {
      _collect(path);
    }
  }

  /// `if (…) { … }`, `else`, `when (…) { … }`, loops and `try`: their
  /// bodies are read under [ktsOpaque].
  void _control(List<String> path) {
    _pos++;
    if (_peek.isSymbol('(')) _parenthesized(path);
    while (_peek.kind == _Kind.newline) {
      _pos++;
    }
    final inner = [...path, ktsOpaque];
    if (_peek.isSymbol('{')) {
      final open = _peek;
      _pos++;
      _opaqueBody(path, open);
    } else if (_peek.kind != _Kind.end && !_peek.isSymbol('}')) {
      _statement(inner);
    }
  }

  /// A statement that starts with a name: an assignment, a block, a call,
  /// or something else.
  void _named(List<String> path) {
    final first = _peek;
    final names = [first.text];
    _pos++;
    while ((_peek.isSymbol('.') || _peek.isSymbol('?.')) &&
        _ahead(1).kind == _Kind.name) {
      names.add(_ahead(1).text);
      _pos += 2;
    }
    _typeArguments();
    final prefix = [...path, ...names.sublist(0, names.length - 1)];
    final next = _peek;
    if (next.isSymbol('=') || next.isSymbol('+=') || next.isSymbol('-=')) {
      _pos++;
      // `x =` with the value on the next line.
      while (_peek.kind == _Kind.newline) {
        _pos++;
      }
      final tokens = _collect(path);
      assignments.add(
        KtsAssignment(
          path: [...path, ...names],
          value: next.text == '='
              ? _classify(tokens)
              : KtsComputed(_shorten('${next.text} ${_join(tokens)}')),
          line: first.line,
        ),
      );
    } else if (next.isSymbol('{')) {
      _pos++;
      if (_scopeFunctions.contains(names.last)) {
        _opaqueBody(path, next, inside: [...prefix, ktsOpaque]);
        return;
      }
      final blockPath = [...path, ...names];
      blocks.add(KtsBlock(path: blockPath, line: first.line));
      body(blockPath, openLine: next.line);
    } else if (next.isSymbol('(')) {
      final arguments = _parenthesized(path);
      if (_peek.isSymbol('{')) {
        final open = _peek;
        _pos++;
        if (names.last == 'with') {
          // `with(android.defaultConfig) { … }`: read as if inside it, but
          // marked.
          final receiver = _isDottedName(arguments)
              ? [
                  for (final token in arguments)
                    if (token.kind == _Kind.name) token.text,
                ]
              : const <String>[];
          _opaqueBody(path, open, inside: [...prefix, ktsOpaque, ...receiver]);
          return;
        }
        final name = _containerCalls.contains(names.last)
            ? _plainString(arguments)
            : null;
        final blockPath = [...prefix, name ?? ktsOpaque];
        blocks.add(KtsBlock(path: blockPath, line: first.line));
        body(blockPath, openLine: open.line);
        return;
      }
      final infix = <String, KtsValue>{};
      while (_peek.kind == _Kind.name && _startsValue(_ahead(1))) {
        final word = _peek.text;
        _pos++;
        final valueTokens = [_peek];
        _pos++;
        while (valueTokens.last.kind == _Kind.name &&
            _peek.isSymbol('.') &&
            _ahead(1).kind == _Kind.name) {
          valueTokens.addAll([_peek, _ahead(1)]);
          _pos += 2;
        }
        if (_peek.isSymbol('(')) {
          valueTokens.add(_peek);
          valueTokens.addAll(_parenthesized(path));
          valueTokens.add(_Token(_Kind.symbol, ')', _peek.line));
        }
        infix[word] = _classify(valueTokens);
      }
      KtsCall call(Map<String, KtsValue> infix) => KtsCall(
        path: prefix,
        name: names.last,
        arguments: _join(arguments),
        argument: _single(arguments),
        infix: infix,
        line: first.line,
      );
      final index = calls.length;
      calls.add(call(infix));
      if (_trailingAssignment(path, prefix, names.last, arguments)) return;
      // Whatever follows, such as `.apply { … }`.
      final rest = _collect(path);
      if (rest.isNotEmpty && infix.isNotEmpty) {
        // `version "8." + "1.0"`: the value goes on past what was read.
        final word = infix.keys.last;
        infix[word] = KtsComputed(
          _shorten('${infix[word]!.text} ${_join(rest)}'),
        );
        calls[index] = call(infix);
      }
    } else {
      _collect(path);
    }
  }

  /// `getByName("release").isMinifyEnabled = true`: after a call, a dotted
  /// name that is assigned to. Recorded with a [ktsOpaque] segment where
  /// the call was, since the call's result is not followed. Returns whether
  /// it was one.
  bool _trailingAssignment(
    List<String> path,
    List<String> prefix,
    String callName,
    List<_Token> arguments,
  ) {
    var j = _pos;
    final rest = <String>[];
    while ((_tokens[j].isSymbol('.') || _tokens[j].isSymbol('?.')) &&
        _tokens[j + 1].kind == _Kind.name) {
      rest.add(_tokens[j + 1].text);
      j += 2;
    }
    final op = _tokens[j];
    if (rest.isEmpty ||
        !(op.isSymbol('=') || op.isSymbol('+=') || op.isSymbol('-='))) {
      return false;
    }
    final line = _tokens[_pos].line;
    _pos = j + 1;
    while (_peek.kind == _Kind.newline) {
      _pos++;
    }
    final tokens = _collect(path);
    final entry = _containerCalls.contains(callName)
        ? _plainString(arguments)
        : null;
    assignments.add(
      KtsAssignment(
        path: [...prefix, ?entry, ktsOpaque, ...rest],
        value: op.text == '='
            ? _classify(tokens)
            : KtsComputed(_shorten('${op.text} ${_join(tokens)}')),
        line: line,
      ),
    );
    return true;
  }

  bool _startsValue(_Token token) =>
      token.kind == _Kind.string ||
      token.kind == _Kind.number ||
      (token.kind == _Kind.name &&
          !_controlWords.contains(token.text) &&
          !_declarationWords.contains(token.text));

  /// Skips `<…>` after a name when it holds only type names and is
  /// followed by `(` or `{`, as in `tasks.register<Delete>("clean")`.
  void _typeArguments() {
    if (!_peek.isSymbol('<')) return;
    var depth = 0;
    var k = _pos;
    for (; k < _tokens.length; k++) {
      final token = _tokens[k];
      if (token.isSymbol('<')) {
        depth++;
      } else if (token.isSymbol('>')) {
        depth--;
        if (depth == 0) break;
      } else if (!(token.kind == _Kind.name ||
          token.isSymbol('.') ||
          token.isSymbol(',') ||
          token.isSymbol('?') ||
          token.isSymbol('*'))) {
        return;
      }
    }
    if (k + 1 >= _tokens.length) return;
    final after = _tokens[k + 1];
    if (after.isSymbol('(') || after.isSymbol('{')) _pos = k + 1;
  }

  /// Reads the body of a `{` (already consumed) that Appstein doesn't
  /// follow, under [ktsOpaque], and records it as a block so that
  /// [KtsScript.blocksIn] shows something was declared here.
  void _opaqueBody(List<String> path, _Token open, {List<String>? inside}) {
    final blockPath = inside ?? [...path, ktsOpaque];
    blocks.add(KtsBlock(path: blockPath, line: open.line));
    body(blockPath, openLine: open.line);
  }

  /// Consumes `( … )` and returns the tokens inside, without newlines. A
  /// lambda inside is read under [ktsOpaque] and stands as `{…}`.
  List<_Token> _parenthesized(List<String> path) {
    final open = _peek;
    _pos++;
    final inner = <_Token>[];
    var depth = 1;
    while (true) {
      final token = _peek;
      if (token.kind == _Kind.end) {
        throw KtsFormatException('a "(" is never closed', open.line);
      }
      if (token.isSymbol('{')) {
        _pos++;
        _opaqueBody(path, token);
        inner.add(_Token(_Kind.symbol, '{…}', token.line));
        continue;
      }
      if (token.isSymbol('}')) {
        throw KtsFormatException('a "}" inside "( )"', token.line);
      }
      if (token.isSymbol('(') || token.isSymbol('[')) depth++;
      if (token.isSymbol(')') || token.isSymbol(']')) {
        depth--;
        if (depth == 0) {
          _pos++;
          return inner;
        }
      }
      if (token.kind != _Kind.newline) inner.add(token);
      _pos++;
    }
  }

  /// Consumes the rest of a statement and returns its tokens. Lambdas in
  /// it are read under [ktsOpaque] and stand as `{…}`. After `->` (a `when`
  /// branch), the rest is read as a statement of its own.
  List<_Token> _collect(List<String> path, {bool lineOnly = false}) {
    final tokens = <_Token>[];
    var depth = 0;
    while (true) {
      final token = _peek;
      if (token.kind == _Kind.end) {
        if (depth > 0) {
          throw KtsFormatException('a bracket is never closed', token.line);
        }
        return tokens;
      }
      if (depth == 0 && (token.isSymbol(';') || token.isSymbol('}'))) {
        return tokens;
      }
      if (token.kind == _Kind.newline) {
        if (depth > 0 || (!lineOnly && _continues(tokens))) {
          _pos++;
          continue;
        }
        return tokens;
      }
      if (token.isSymbol('{')) {
        _pos++;
        _opaqueBody(path, token);
        tokens.add(_Token(_Kind.symbol, '{…}', token.line));
        continue;
      }
      if (depth == 0 && token.isSymbol('->')) {
        _pos++;
        _statement(path.contains(ktsOpaque) ? path : [...path, ktsOpaque]);
        return tokens;
      }
      if (token.isSymbol('(') || token.isSymbol('[')) depth++;
      if (token.isSymbol(')') || token.isSymbol(']')) {
        if (depth == 0) {
          throw KtsFormatException(
            'a "${token.text}" closes nothing',
            token.line,
          );
        }
        depth--;
      }
      tokens.add(token);
      _pos++;
    }
  }

  /// Whether the statement in [tokens] goes on past the newline at the
  /// cursor.
  bool _continues(List<_Token> tokens) {
    // Nothing yet, such as after a call statement: the line ends it.
    if (tokens.isEmpty) return false;
    final last = tokens.last;
    var k = _pos;
    while (_tokens[k].kind == _Kind.newline) {
      k++;
    }
    if (last.kind == _Kind.symbol && _continuesAfter.contains(last.text)) {
      // `import java.util.*`: the star is a wildcard, not a multiplication.
      final afterDot =
          tokens.length > 1 && tokens[tokens.length - 2].isSymbol('.');
      if (last.text == '*' && afterDot) return false;
      // `List<String>` ends a line as often as `a >` does: a line that
      // starts a statement of its own is never swallowed.
      if (_weakContinuers.contains(last.text)) return !_startsStatement(k);
      return true;
    }
    final next = _tokens[k];
    return next.kind == _Kind.symbol && _continuesBefore.contains(next.text);
  }

  /// Whether the tokens from [k] start a statement of their own: a name
  /// (dotted) followed by `{`, `(…) {` or an assignment.
  bool _startsStatement(int k) {
    if (_tokens[k].kind != _Kind.name) return false;
    var j = k + 1;
    while ((_tokens[j].isSymbol('.') || _tokens[j].isSymbol('?.')) &&
        _tokens[j + 1].kind == _Kind.name) {
      j += 2;
    }
    final token = _tokens[j];
    if (token.isSymbol('{') ||
        token.isSymbol('=') ||
        token.isSymbol('+=') ||
        token.isSymbol('-=')) {
      return true;
    }
    if (!token.isSymbol('(')) return false;
    var depth = 0;
    for (; j < _tokens.length; j++) {
      final t = _tokens[j];
      if (t.kind == _Kind.end) return false;
      if (t.isSymbol('(')) depth++;
      if (t.isSymbol(')')) {
        depth--;
        if (depth == 0) break;
      }
    }
    j++;
    while (j < _tokens.length && _tokens[j].kind == _Kind.newline) {
      j++;
    }
    return j < _tokens.length && _tokens[j].isSymbol('{');
  }

  KtsValue _classify(List<_Token> tokens) {
    final text = _join(tokens);
    if (tokens.length == 1) {
      final token = tokens.single;
      if (token.kind == _Kind.string && token.value != null) {
        return KtsString(token.value!, text);
      }
      if (token.kind == _Kind.number) {
        final number = int.tryParse(token.text);
        if (number != null) return KtsInt(number, text);
      }
      if (token.isName('true') || token.isName('false')) {
        return KtsBool(token.text == 'true', text);
      }
    }
    if (_isDottedName(tokens)) return KtsName(text);
    final n = tokens.length;
    if (n >= 4 &&
        tokens[n - 3].isSymbol('(') &&
        tokens[n - 1].isSymbol(')') &&
        tokens[n - 2].kind == _Kind.string &&
        tokens[n - 2].value != null &&
        _isDottedName(tokens.sublist(0, n - 3))) {
      return KtsCallValue(
        _join(tokens.sublist(0, n - 3)),
        tokens[n - 2].value!,
        text,
      );
    }
    return KtsComputed(_shorten(text));
  }

  KtsValue? _single(List<_Token> arguments) {
    if (arguments.isEmpty) return null;
    return switch (_classify(arguments)) {
      KtsComputed() || KtsCallValue() => null,
      final value => value,
    };
  }

  static String? _plainString(List<_Token> arguments) =>
      arguments.length == 1 && arguments.single.kind == _Kind.string
      ? arguments.single.value
      : null;

  static bool _isDottedName(List<_Token> tokens) {
    if (tokens.isEmpty || tokens.length.isEven) return false;
    for (var i = 0; i < tokens.length; i++) {
      final ok = i.isEven
          ? tokens[i].kind == _Kind.name &&
                !tokens[i].isName('true') &&
                !tokens[i].isName('false')
          : tokens[i].isSymbol('.');
      if (!ok) return false;
    }
    return true;
  }

  static String _join(List<_Token> tokens) {
    final out = StringBuffer();
    for (var k = 0; k < tokens.length; k++) {
      final token = tokens[k];
      if (k > 0) {
        final before = tokens[k - 1];
        final tight =
            token.isSymbol('.') ||
            token.isSymbol('?.') ||
            token.isSymbol(')') ||
            token.isSymbol(']') ||
            token.isSymbol(',') ||
            before.isSymbol('.') ||
            before.isSymbol('?.') ||
            before.isSymbol('(') ||
            before.isSymbol('[') ||
            ((token.isSymbol('(') || token.isSymbol('[')) &&
                before.kind == _Kind.name);
        if (!tight) out.write(' ');
      }
      out.write(token.text);
    }
    return out.toString();
  }

  static String _shorten(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 80 ? flat : '${flat.substring(0, 77)}...';
  }
}
