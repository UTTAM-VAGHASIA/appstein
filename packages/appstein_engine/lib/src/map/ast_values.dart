import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

/// The value of [expression] when it is a compile-time constant string,
/// else null. It reads literals, adjacent literals, interpolations of
/// constants, and references to `const` variables and fields (such as
/// `Routes.home`), which the analyzer evaluates.
String? constantString(Expression? expression) {
  switch (expression) {
    case SimpleStringLiteral(:final value):
      return value;
    case AdjacentStrings(:final strings):
      final buffer = StringBuffer();
      for (final part in strings) {
        final value = constantString(part);
        if (value == null) return null;
        buffer.write(value);
      }
      return buffer.toString();
    case StringInterpolation(:final elements):
      final buffer = StringBuffer();
      for (final element in elements) {
        switch (element) {
          case InterpolationString(:final value):
            buffer.write(value);
          case InterpolationExpression(:final expression):
            final value = constantString(expression);
            if (value == null) return null;
            buffer.write(value);
        }
      }
      return buffer.toString();
    case ParenthesizedExpression(:final expression):
      return constantString(expression);
    case Identifier(:final element):
      return _constantValue(element);
    case PropertyAccess(:final propertyName):
      return _constantValue(propertyName.element);
    default:
      return null;
  }
}

String? _constantValue(Element? element) {
  final variable = switch (element) {
    GetterElement(:final variable) => variable,
    final VariableElement variable => variable,
    _ => null,
  };
  if (variable == null || !variable.isConst) return null;
  return variable.computeConstantValue()?.toStringValue();
}

/// The expression [body] returns when it is a single plain return: `=> x`,
/// or a block whose only `return` is its last statement. A `return` inside
/// a nested function belongs to that function, so it doesn't count.
Expression? singleReturn(FunctionBody body) {
  if (body is ExpressionFunctionBody) return body.expression;
  if (body is! BlockFunctionBody) return null;
  final finder = _ReturnFinder();
  body.block.accept(finder);
  final statements = body.block.statements;
  if (finder.returns.length != 1 ||
      statements.isEmpty ||
      !identical(statements.last, finder.returns.single)) {
    return null;
  }
  return finder.returns.single.expression;
}

final class _ReturnFinder extends RecursiveAstVisitor<void> {
  final returns = <ReturnStatement>[];

  @override
  void visitReturnStatement(ReturnStatement node) {
    returns.add(node);
    super.visitReturnStatement(node);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    // Its returns are its own.
  }
}

/// The named arguments of a call, by name.
final class NamedArguments {
  /// Reads the named arguments in [list].
  NamedArguments(ArgumentList list)
    : _values = {
        for (final argument in list.arguments.whereType<NamedArgument>())
          argument.name.lexeme: argument.argumentExpression,
      };

  final Map<String, Expression> _values;

  /// The expression passed as [name], or null.
  Expression? operator [](String name) => _values[name];

  /// Whether [name] was passed.
  bool has(String name) => _values.containsKey(name);
}
