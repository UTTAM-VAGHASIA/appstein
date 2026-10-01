import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

import 'toolchain_files.dart';

/// What Appstein reads from Flutter's `gradle_utils.dart` (spec §12).
final class GradleUtilsFacts {
  /// Creates the facts.
  const GradleUtilsFacts({
    required this.template,
    required this.flutterMinimums,
    required this.maxKnown,
    required this.javaGradle,
    required this.javaAgp,
  });

  /// The versions `flutter create` writes.
  final AndroidTemplate template;

  /// What `flutter doctor` requires.
  final AndroidMinimums flutterMinimums;

  /// The newest versions Flutter knows.
  final AndroidMaxKnown maxKnown;

  /// Java↔Gradle compatibility, in Flutter's order.
  final List<JavaGradleCompat> javaGradle;

  /// AGP↔Java compatibility, in Flutter's order.
  final List<JavaAgpCompat> javaAgp;
}

/// Reads the toolchain facts from the text of Flutter's `gradle_utils.dart`.
///
/// The file is parsed with the Dart analyzer's parser (no resolution), and
/// the top-level declarations Appstein needs are evaluated. These are:
/// - string and integer literals;
/// - interpolations of, and references to, other top-level declarations;
/// - `Version(a, b, c)` calls.
///
/// Throws [ToolchainParseException] when a declaration is missing or has
/// another shape, so a changed file is reported instead of misread.
GradleUtilsFacts parseGradleUtils(String text) {
  final values = _TopLevelValues(
    parseString(content: text, throwIfDiagnostics: false).unit,
  );
  return GradleUtilsFacts(
    template: AndroidTemplate(
      gradle: values.string('templateDefaultGradleVersion'),
      agp: values.string('templateAndroidGradlePluginVersion'),
      kgp: values.string('templateKotlinGradlePluginVersion'),
      ndk: values.string('ndkVersion'),
      compileSdk: values.integer('compileSdkVersionInt'),
      targetSdk: values.integer('targetSdkVersion'),
      minSdk: values.integer('minSdkVersionInt'),
    ),
    flutterMinimums: AndroidMinimums(
      compileSdk: values.integer('compileSdkVersionInt'),
      buildTools: values.string('minBuildToolsVersion'),
      java: VersionThreshold(
        warnBelow: values.string('warnJavaMinVersionAndroid'),
        errorBelow: values.string('errorJavaMinVersionAndroid'),
      ),
    ),
    maxKnown: AndroidMaxKnown(
      gradle: values.string('maxKnownAndSupportedGradleVersion'),
      kgp: values.string('maxKnownAndSupportedKgpVersion'),
      agp: values.string('maxKnownAgpVersion'),
      agpWithFullKotlinSupport: values.string(
        'maxKnownAgpVersionWithFullKotlinSupport',
      ),
    ),
    javaGradle: [
      for (final row in values.rows(
        '_javaGradleCompatList',
        'JavaGradleCompat',
      ))
        JavaGradleCompat(
          javaMin: row.string('javaMin'),
          javaMax: row.string('javaMax'),
          gradleMin: row.string('gradleMin'),
          gradleMax: row.optionalString('gradleMax'),
        ),
    ],
    javaAgp: [
      for (final row in values.rows('_javaAgpCompatList', 'JavaAgpCompat'))
        JavaAgpCompat(
          javaMin: row.string('javaMin'),
          javaDefault: row.string('javaDefault'),
          agpMin: row.string('agpMin'),
          agpMax: row.string('agpMax'),
        ),
    ],
  );
}

ToolchainParseException _error(String message) =>
    ToolchainParseException(ToolchainFiles.gradleUtils, message);

/// The top-level declarations of a parsed file, evaluated on demand.
final class _TopLevelValues {
  _TopLevelValues(CompilationUnit unit) {
    for (final declaration in unit.declarations) {
      if (declaration is! TopLevelVariableDeclaration) continue;
      for (final variable in declaration.variables.variables) {
        final initializer = variable.initializer;
        if (initializer != null) {
          _initializers[variable.name.lexeme] = initializer;
        }
      }
    }
  }

  final _initializers = <String, Expression>{};

  String string(String name) => '${_evaluate(name, _find(name), 0)}';

  int integer(String name) {
    final value = _evaluate(name, _find(name), 0);
    if (value is int) return value;
    final parsed = int.tryParse('$value');
    if (parsed == null) throw _error('$name is not a whole number: $value');
    return parsed;
  }

  /// The entries of the list [name], each a call of [constructor] with
  /// named arguments only.
  List<_Row> rows(String name, String constructor) {
    final list = _find(name);
    if (list is! ListLiteral) throw _error('$name is not a list');
    return [
      for (final element in list.elements)
        if (element is MethodInvocation &&
            element.target == null &&
            element.methodName.name == constructor)
          _Row(this, name, element.argumentList)
        else
          throw _error(
            '$name has an entry of another shape: ${element.toSource()}',
          ),
    ];
  }

  Expression _find(String name) =>
      _initializers[name] ?? (throw _error('no top-level $name'));

  Object _evaluate(String name, Expression expression, int depth) {
    if (depth > 8) throw _error('$name refers to itself');
    if (expression is SimpleStringLiteral) return expression.value;
    if (expression is IntegerLiteral && expression.value != null) {
      return expression.value!;
    }
    if (expression is AdjacentStrings) {
      return [
        for (final part in expression.strings) _evaluate(name, part, depth + 1),
      ].join();
    }
    if (expression is StringInterpolation) {
      final buffer = StringBuffer();
      for (final element in expression.elements) {
        if (element is InterpolationString) {
          buffer.write(element.value);
        } else if (element is InterpolationExpression) {
          buffer.write(_evaluate(name, element.expression, depth + 1));
        }
      }
      return buffer.toString();
    }
    if (expression is SimpleIdentifier) {
      final reference = expression.name;
      return _evaluate(reference, _find(reference), depth + 1);
    }
    if (expression is MethodInvocation &&
        expression.target == null &&
        expression.methodName.name == 'Version') {
      final parts = [
        for (final argument in expression.argumentList.arguments)
          argument.argumentExpression,
      ];
      if (parts.length == 3 &&
          parts.every((part) => part is IntegerLiteral && part.value != null)) {
        return parts.map((part) => (part as IntegerLiteral).value).join('.');
      }
    }
    throw _error('$name has an unexpected value: ${expression.toSource()}');
  }
}

/// One entry of a compatibility list: its named arguments.
final class _Row {
  _Row(this._values, this._list, ArgumentList arguments) {
    for (final argument in arguments.arguments) {
      if (argument is! NamedArgument) {
        throw _error('$_list has an entry with a positional argument');
      }
      _arguments[argument.name.lexeme] = argument.argumentExpression;
    }
  }

  final _TopLevelValues _values;
  final String _list;
  final _arguments = <String, Expression>{};

  String string(String key) =>
      optionalString(key) ?? (throw _error('$_list has an entry without $key'));

  String? optionalString(String key) {
    final expression = _arguments[key];
    if (expression == null) return null;
    return '${_values._evaluate('$_list.$key', expression, 0)}';
  }
}
