import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

import '../../map/ast_values.dart';
import '../../map/project_analysis.dart';

/// Reads the go_router routes reachable from every `GoRouter(...)` in `lib/`
/// (spec §6.5). It reads nested routes and the routes inside shells, joins
/// nested paths, and records each route's screen. What can't be resolved
/// statically is marked unresolved with a reason, never guessed.
///
/// Routes and routers are listed by file, then in source order.
RoutesMap readRoutes(ProjectAnalysis analysis) {
  final routes = <MapRoute>[];
  final routers = <MapRouter>[];
  for (final library in analysis.libraries) {
    if (!library.path.startsWith('lib/')) continue;
    for (final unit in library.result.units) {
      final file = analysis.relativePath(unit.path);
      if (file == null) continue;
      final finder = _RouterFinder();
      unit.unit.accept(finder);
      final reader = _RouteReader(analysis, file, unit.lineInfo, routes);
      for (final router in finder.routers) {
        final arguments = NamedArguments(router.argumentList);
        routers.add(
          MapRouter(
            file: file,
            line: reader.lineOf(router),
            redirect: arguments.has('redirect'),
          ),
        );
        final list = arguments['routes'];
        if (list == null) {
          reader.unresolved(
            router,
            const _Parent.top(),
            'this GoRouter has no routes list',
          );
        } else {
          reader.readList(list, const _Parent.top());
        }
      }
    }
  }
  return RoutesMap(
    routes: _byFile(routes, (r) => r.file),
    routers: _byFile(routers, (r) => r.file),
  );
}

/// Joins a nested route's [child] path to its [parent]'s, as go_router's
/// `concatenatePaths` does: the non-empty segments of both, after one `/`.
/// A top-level path ([parent] null) is kept as written.
String joinRoutePath(String? parent, String child) {
  if (parent == null) return child;
  final segments = [
    ...parent.split('/'),
    ...child.split('/'),
  ].where((segment) => segment.isNotEmpty);
  return '/${segments.join('/')}';
}

/// [items] grouped by their file, files sorted, each file's items in their
/// original (source) order.
List<T> _byFile<T>(List<T> items, String Function(T) fileOf) {
  final groups = <String, List<T>>{};
  for (final item in items) {
    (groups[fileOf(item)] ??= []).add(item);
  }
  return [for (final file in groups.keys.toList()..sort()) ...groups[file]!];
}

/// The name of [node]'s class when that class comes from
/// `package:go_router`, such as `GoRoute`; null for any other class.
String? _goRouterClass(InstanceCreationExpression node) {
  final element = node.constructorName.type.element;
  if (element is! ClassElement) return null;
  final uri = element.library.uri;
  final fromGoRouter =
      uri.scheme == 'package' &&
      uri.pathSegments.isNotEmpty &&
      uri.pathSegments.first == 'go_router';
  return fromGoRouter ? element.name : null;
}

final class _RouterFinder extends RecursiveAstVisitor<void> {
  final routers = <InstanceCreationExpression>[];

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    if (_goRouterClass(node) == 'GoRouter') routers.add(node);
    super.visitInstanceCreationExpression(node);
  }
}

/// The enclosing `GoRoute`'s full path, if any.
final class _Parent {
  const _Parent(this.path, {required this.unresolved});

  const _Parent.top() : path = null, unresolved = false;

  final String? path;

  /// Whether the enclosing route's path couldn't be resolved.
  final bool unresolved;
}

final class _RouteReader {
  _RouteReader(this.analysis, this.file, this.lineInfo, this.routes);

  final ProjectAnalysis analysis;
  final String file;
  final LineInfo lineInfo;
  final List<MapRoute> routes;

  int lineOf(AstNode node) => lineInfo.getLocation(node.offset).lineNumber;

  void unresolved(AstNode node, _Parent parent, String reason) => routes.add(
    MapRoute(
      parent: parent.path,
      file: file,
      line: lineOf(node),
      unresolved: true,
      reason: reason,
    ),
  );

  void readList(Expression list, _Parent parent) {
    if (list is! ListLiteral) {
      final typed = list is SimpleIdentifier && list.name == r'$appRoutes';
      unresolved(
        list,
        parent,
        typed
            ? 'typed routes (go_router_builder) are not read yet'
            : 'the routes are not a list literal',
      );
      return;
    }
    for (final element in list.elements) {
      if (element is Expression) {
        readRoute(element, parent);
      } else {
        unresolved(
          element,
          parent,
          'a spread or a condition in a routes list is not read',
        );
      }
    }
  }

  void readRoute(Expression route, _Parent parent) {
    const notARoute =
        'the route is not a GoRoute, ShellRoute or StatefulShellRoute '
        'constructor call';
    if (route is! InstanceCreationExpression) {
      unresolved(route, parent, notARoute);
      return;
    }
    final arguments = NamedArguments(route.argumentList);
    switch (_goRouterClass(route)) {
      case 'GoRoute':
        _goRoute(route, arguments, parent);
      case 'ShellRoute':
        if (arguments['routes'] case final list?) readList(list, parent);
      case 'StatefulShellRoute':
        _branches(route, arguments['branches'], parent);
      default:
        unresolved(route, parent, notARoute);
    }
  }

  void _branches(AstNode at, Expression? branches, _Parent parent) {
    if (branches is! ListLiteral) {
      unresolved(branches ?? at, parent, 'the branches are not a list literal');
      return;
    }
    for (final branch in branches.elements) {
      if (branch is InstanceCreationExpression &&
          _goRouterClass(branch) == 'StatefulShellBranch') {
        if (NamedArguments(branch.argumentList)['routes'] case final list?) {
          readList(list, parent);
        }
      } else {
        unresolved(
          branch,
          parent,
          'the branch is not a StatefulShellBranch constructor call',
        );
      }
    }
  }

  void _goRoute(
    InstanceCreationExpression route,
    NamedArguments arguments,
    _Parent parent,
  ) {
    final declared = constantString(arguments['path']);
    final path = parent.unresolved || declared == null
        ? null
        : joinRoutePath(parent.path, declared);
    final screen = _screen(arguments);
    final reason = parent.unresolved
        ? "the parent route's path is not a constant string"
        : declared == null
        ? 'the path is not a constant string'
        : screen.reason;
    routes.add(
      MapRoute(
        path: path,
        name: constantString(arguments['name']),
        screen: screen.ref,
        parent: parent.path,
        redirect: arguments.has('redirect'),
        file: file,
        line: lineOf(route),
        unresolved: reason != null,
        reason: reason,
      ),
    );
    if (arguments['routes'] case final children?) {
      readList(children, _Parent(path, unresolved: path == null));
    }
  }

  ({CodeRef? ref, String? reason}) _screen(NamedArguments arguments) {
    // go_router uses pageBuilder when both are given.
    final pageBuilder = arguments['pageBuilder'];
    final builder = pageBuilder ?? arguments['builder'];
    if (builder == null) return (ref: null, reason: null);
    if (builder is! FunctionExpression) {
      return (ref: null, reason: 'the builder is not a function literal');
    }
    final returned = singleReturn(builder.body);
    if (returned == null) {
      return (ref: null, reason: 'the builder is not a single plain return');
    }
    var widget = returned;
    if (pageBuilder != null) {
      final child = returned is InstanceCreationExpression
          ? NamedArguments(returned.argumentList)['child']
          : null;
      if (child == null) {
        return (
          ref: null,
          reason:
              "the page builder doesn't return a page with a child: "
              'argument',
        );
      }
      widget = child;
    }
    if (widget is! InstanceCreationExpression) {
      return (
        ref: null,
        reason: "the builder doesn't return a widget constructor call",
      );
    }
    final element = widget.constructorName.type.element;
    final name = element?.name;
    final location = element == null
        ? null
        : analysis.locationOf(element.firstFragment);
    if (name == null || location == null || !location.file.startsWith('lib/')) {
      return (
        ref: null,
        reason:
            'the builder returns ${name ?? 'a widget'}, which is not declared '
            'in this project',
      );
    }
    return (ref: CodeRef(name: name, file: location.file), reason: null);
  }
}
