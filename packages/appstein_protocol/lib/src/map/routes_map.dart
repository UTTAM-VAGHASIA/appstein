import '../json_fields.dart';
import 'code_ref.dart';

/// One go_router route in `routes.json` (spec §6.5).
final class MapRoute {
  /// Creates a route.
  const MapRoute({
    this.path,
    this.name,
    this.screen,
    this.parent,
    this.redirect = false,
    this.redirectTo,
    required this.file,
    required this.line,
    this.unresolved = false,
    this.reason,
  });

  factory MapRoute._read(JsonFields fields) {
    final screen = fields.optionalObject('screen');
    return MapRoute(
      path: fields.optionalString('path'),
      name: fields.optionalString('name'),
      screen: screen == null ? null : CodeRef.read(screen),
      parent: fields.optionalString('parent'),
      redirect: fields.boolean('redirect'),
      // Absent in a map written before slice 1c.5.
      redirectTo: fields.optionalString('redirectTo'),
      file: fields.string('file'),
      line: fields.integer('line'),
      unresolved: fields.boolean('unresolved'),
      reason: fields.optionalString('reason'),
    );
  }

  /// The full path, with the parents' paths joined in, or null when it
  /// can't be resolved statically.
  final String? path;

  /// The route's `name:`, when it is a constant string.
  final String? name;

  /// The widget the builder returns, when that is a widget declared in the
  /// project.
  final CodeRef? screen;

  /// The full path of the enclosing `GoRoute`, or null at the top.
  final String? parent;

  /// Whether the route has its own `redirect:`.
  final bool redirect;

  /// The path the route redirects to, when its `redirect:` is a function
  /// that only returns one constant path; null for any other redirect (a
  /// condition, a computed path), which is never guessed (spec §6.5).
  final String? redirectTo;

  /// The file that declares the route.
  final String file;

  /// The 1-based line where the route's constructor call starts.
  final int line;

  /// Whether the path or the screen couldn't be resolved statically.
  final bool unresolved;

  /// Why it is [unresolved].
  final String? reason;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'path': path,
    'name': name,
    'screen': screen?.toJson(),
    'parent': parent,
    'redirect': redirect,
    'redirectTo': redirectTo,
    'file': file,
    'line': line,
    'unresolved': unresolved,
    'reason': reason,
  };
}

/// One `GoRouter(...)` in the project.
final class MapRouter {
  /// Creates a router entry.
  const MapRouter({
    required this.file,
    required this.line,
    required this.redirect,
  });

  factory MapRouter._read(JsonFields fields) => MapRouter(
    file: fields.string('file'),
    line: fields.integer('line'),
    redirect: fields.boolean('redirect'),
  );

  /// The file that creates the router.
  final String file;

  /// The 1-based line where the constructor call starts.
  final int line;

  /// Whether the router has a top-level `redirect:`.
  final bool redirect;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'file': file,
    'line': line,
    'redirect': redirect,
  };
}

/// The contents of `map/routes.json`.
final class RoutesMap {
  /// Creates the map. Both lists are sorted by file, then line.
  const RoutesMap({required this.routes, required this.routers});

  /// Reads the map from its JSON form, ignoring `meta`.
  ///
  /// Throws a [FormatException] for a missing or mistyped field.
  factory RoutesMap.fromJson(Map<String, Object?> json) {
    final fields = JsonFields('routes.json', json);
    return RoutesMap(
      routes: [for (final r in fields.objects('routes')) MapRoute._read(r)],
      routers: [for (final r in fields.objects('routers')) MapRouter._read(r)],
    );
  }

  /// The routes.
  final List<MapRoute> routes;

  /// The routers.
  final List<MapRouter> routers;

  /// The JSON form.
  Map<String, Object?> toJson() => {
    'routes': [for (final r in routes) r.toJson()],
    'routers': [for (final r in routers) r.toJson()],
  };
}
