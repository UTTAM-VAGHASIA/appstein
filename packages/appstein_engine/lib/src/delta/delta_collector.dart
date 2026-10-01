import 'dart:io';

import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import '../map/project_analysis.dart';
import 'delta_facts.dart';
import 'fix_data.dart';

/// Collects what the version delta lists about the project in [analysis]
/// (spec §6.4), besides the curated notes.
///
/// - **Deprecated:**
///   - every declaration, member and parameter with a `Deprecated`
///     annotation, of any kind, that the libraries the project imports
///     export, except the project's own;
///   - a member inherited from a private superclass is listed under the
///     public class that exposes it.
/// - **Removed, changed and moved:**
///   - the migrations in the `fix_data` files (`fix_data.yaml` or
///     `fix_data/**.yaml` in `lib/`) of each package the project imports,
///     and in the Dart SDK's `lib/_internal/fix_data.yaml` under
///     [dartSdkPath];
///   - a migration counts when the project imports one of its libraries
///     directly, which is the rule `dart fix` uses;
///   - a migration of an element or parameter that is still there and
///     deprecated is attached to that deprecation.
/// - **Unread:** the migration files that couldn't be read, and why.
///
/// It never throws for a package's bad `fix_data` file.
DeltaFacts collectDelta(
  ProjectAnalysis analysis, {
  required String dartSdkPath,
}) => _Collector(analysis, dartSdkPath).run();

typedef _MigrationFile = ({String name, String path, Uri base});

final class _Found {
  _Found(this.group, this.display, this.kind, this.message);

  final String group;
  String display;
  final DeprecationKind kind;
  final String? message;
  final migrations = <String>{};
}

final class _Collector {
  _Collector(this.analysis, this.dartSdkPath);

  final ProjectAnalysis analysis;
  final String dartSdkPath;

  /// Every library the project imports, except its own, by URI.
  final _imported = <Uri, LibraryElement>{};

  /// Each deprecation found, by its element and kind.
  final _found = <(Element, DeprecationKind), _Found>{};

  /// Every library reachable through imports and exports from the ones the
  /// project imports, by URI (the analyzer loads them with their importer),
  /// built the first time it is needed.
  late final Map<Uri, LibraryElement> _loaded = _loadReachable();

  Map<Uri, LibraryElement> _loadReachable() {
    final all = <Uri, LibraryElement>{..._imported};
    final queue = [..._imported.values];
    while (queue.isNotEmpty) {
      final library = queue.removeLast();
      for (
        LibraryFragment? fragment = library.firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      ) {
        for (final next in [
          for (final import in fragment.libraryImports) import.importedLibrary,
          for (final export in fragment.libraryExports) export.exportedLibrary,
        ]) {
          if (next == null || all.containsKey(next.uri)) continue;
          all[next.uri] = next;
          queue.add(next);
        }
      }
    }
    return all;
  }

  /// The group of the public library being walked: a deprecation declared in
  /// a private `dart:` library (`dart:_internal`) is listed under it.
  String? _through;

  final _visited = <Element>{};
  final _visitedTypes = <(InstanceElement, String)>{};

  DeltaFacts run() {
    for (final library in analysis.libraries) {
      final element = library.result.element;
      // dart:core is imported by every library, even when no directive says
      // so.
      _import(element.typeProvider.objectType.element.library);
      for (
        LibraryFragment? fragment = element.firstFragment;
        fragment != null;
        fragment = fragment.nextFragment
      ) {
        for (final import in fragment.libraryImports) {
          if (import.importedLibrary case final imported?) _import(imported);
        }
      }
    }
    final uris = _imported.keys.toList()..sort((a, b) => '$a'.compareTo('$b'));
    for (final uri in uris) {
      _through = _group(uri);
      for (final element
          in _imported[uri]!.exportNamespace.definedNames2.values) {
        _visit(element);
      }
    }

    final migrated = <(String, String, MigrationStatus, String)>{};
    final moved = <(String, String?, String)>{};
    final unread = <UnreadMigrations>[];
    for (final file in _migrationFiles(unread)) {
      for (final transform in _read(file, unread)) {
        _classify(transform, migrated, moved);
      }
    }

    final deprecated = <String, DeprecatedApi>{};
    for (final found in _found.values) {
      final key =
          '${found.group}\n${found.display}\n${found.kind.index}\n'
          '${found.message}';
      final migrations = {
        ...?deprecated[key]?.migrations,
        ...found.migrations,
      }.toList()..sort();
      deprecated[key] = DeprecatedApi(
        group: found.group,
        name: found.display,
        kind: found.kind,
        message: found.message,
        migrations: migrations,
      );
    }
    return DeltaFacts(
      deprecated: deprecated.values.toList()
        ..sort(
          (a, b) => _compare([
            a.group.compareTo(b.group),
            a.name.compareTo(b.name),
            a.kind.index.compareTo(b.kind.index),
            (a.message ?? '').compareTo(b.message ?? ''),
          ]),
        ),
      migrated:
          [
            for (final (group, name, status, title) in migrated)
              MigratedApi(
                group: group,
                name: name,
                status: status,
                title: title,
              ),
          ]..sort(
            (a, b) => _compare([
              a.group.compareTo(b.group),
              a.name.compareTo(b.name),
              a.status.index.compareTo(b.status.index),
              a.title.compareTo(b.title),
            ]),
          ),
      moved: [
        for (final (from, to, title) in moved)
          MovedLibrary(from: from, to: to, title: title),
      ]..sort((a, b) => '$a'.compareTo('$b')),
      unread: unread..sort((a, b) => '$a'.compareTo('$b')),
    );
  }

  /// Imports [library] unless it is the project's own, or is a file that is
  /// not (no machine path may reach the delta).
  void _import(LibraryElement? library) {
    if (library == null || _isProjects(library)) return;
    if (library.uri.scheme == 'file') return;
    _imported[library.uri] = library;
  }

  /// Whether [library] is the project's own, decided by its URI and never by
  /// where its files sit: `package:<the project's name>/…`, or a `file:` URI
  /// under the project folder. A path dependency in a subfolder, or a pub
  /// cache inside the project, is therefore not the project's own.
  bool _isProjects(LibraryElement library) {
    final uri = library.uri;
    if (uri.scheme == 'package') {
      return uri.pathSegments.isNotEmpty &&
          uri.pathSegments.first == analysis.packageName;
    }
    return uri.scheme == 'file' &&
        analysis.relativePath(library.firstFragment.source.fullName) != null;
  }

  /// The variable behind a getter or setter that the analyzer made up for a
  /// top-level variable (the namespace holds those, and they carry no
  /// annotations); [element] itself for anything else.
  Element _declared(Element element) =>
      element is PropertyAccessorElement &&
          !identical(element.nonSynthetic, element)
      ? element.variable
      : element;

  /// Notes [element], a name a library exports, with its members and
  /// parameters.
  void _visit(Element element) {
    // A top-level variable shows up as a synthetic getter, and a synthetic
    // setter when it isn't final: note the variable once, by the getter.
    if (element is PropertyAccessorElement &&
        !identical(element.nonSynthetic, element)) {
      if (element is GetterElement) _visit(element.variable);
      return;
    }
    if (!_visited.add(element)) return;
    var name = element.name;
    if (name == null || name.startsWith('_')) return;
    // A top-level setter is named with its `=`, like a member setter.
    if (element is SetterElement) {
      name = name.endsWith('=') ? name : '$name=';
    }
    _note(element, name);
    if (element is ExecutableElement) _noteParameters(element, name);
    if (element is InterfaceElement) {
      _noteMembers(element, name);
      _noteConstructors(element, name);
      for (final supertype in element.allSupertypes) {
        final declaring = supertype.element;
        final declaringName = declaring.name;
        if (declaringName == null) continue;
        _noteMembers(
          declaring,
          declaringName.startsWith('_') ? name : declaringName,
        );
      }
    } else if (element is InstanceElement) {
      _noteMembers(element, name);
    }
  }

  void _noteMembers(InstanceElement type, String owner) {
    if (!_visitedTypes.add((type, owner))) return;
    for (final member in <Element>[
      ...type.fields,
      ...type.getters,
      ...type.methods,
    ]) {
      final name = member.name;
      if (name == null || name.startsWith('_')) continue;
      _note(member, '$owner.$name');
      if (member is ExecutableElement) {
        _noteParameters(member, '$owner.$name');
      }
    }
    for (final setter in type.setters) {
      final name = setter.name;
      if (name == null || name.startsWith('_')) continue;
      final plain = name.endsWith('=')
          ? name.substring(0, name.length - 1)
          : name;
      _note(setter, '$owner.$plain=');
    }
  }

  void _noteConstructors(InterfaceElement type, String owner) {
    for (final constructor in type.constructors) {
      final name = constructor.name;
      if (name != null && name.startsWith('_')) continue;
      final display = _isUnnamed(name) ? '$owner.new' : '$owner.$name';
      _note(constructor, display);
      _noteParameters(constructor, display);
    }
  }

  void _noteParameters(ExecutableElement executable, String owner) {
    for (final parameter in executable.formalParameters) {
      final name = parameter.name;
      if (name == null || name.startsWith('_')) continue;
      _note(parameter, '$owner($name)');
    }
  }

  /// Records each deprecation annotation on [element] under [display],
  /// keeping the first name in sort order when the element is reached
  /// under several names.
  void _note(Element element, String display) {
    final LibraryElement? library = element.library;
    if (library == null || _isProjects(library)) return;
    for (final annotation in element.metadata.annotations) {
      if (!annotation.isDeprecated) continue;
      final kind = _kindOf(annotation);
      final found = _found[(element, kind)];
      if (found == null) {
        _found[(element, kind)] = _Found(
          _groupOf(library.uri),
          display,
          kind,
          _messageOf(annotation),
        );
      } else if (display.compareTo(found.display) < 0) {
        found.display = display;
      }
    }
  }

  /// [_group] of the library that declares something, except that a private
  /// `dart:` library (`dart:_internal`, `dart:_http`) is named by the public
  /// one the walk reached it through, which is what code can import.
  String _groupOf(Uri declared) {
    if (declared.scheme == 'dart' &&
        declared.path.split('/').first.startsWith('_')) {
      return _through ?? _group(declared);
    }
    return _group(declared);
  }

  List<_MigrationFile> _migrationFiles(List<UnreadMigrations> unread) {
    final files = <_MigrationFile>[
      (
        name: 'dart-sdk/lib/_internal/fix_data.yaml',
        path: p.join(dartSdkPath, 'lib', '_internal', 'fix_data.yaml'),
        base: Uri.parse('dart:core'),
      ),
    ];
    final libFolders = <String, String>{};
    for (final MapEntry(key: uri, value: library) in _imported.entries) {
      if (uri.scheme != 'package' || uri.pathSegments.length < 2) continue;
      var folder = library.firstFragment.source.fullName;
      for (var i = 1; i < uri.pathSegments.length; i++) {
        folder = p.dirname(folder);
      }
      libFolders.putIfAbsent(uri.pathSegments.first, () => folder);
    }
    for (final package in libFolders.keys.toList()..sort()) {
      final lib = libFolders[package]!;
      final base = Uri.parse('package:$package/');
      files.add((
        name: 'package:$package/fix_data.yaml',
        path: p.join(lib, 'fix_data.yaml'),
        base: base,
      ));
      final folder = Directory(p.join(lib, 'fix_data'));
      try {
        if (!folder.existsSync()) continue;
        final paths = [
          for (final entity in folder.listSync(recursive: true))
            if (entity is File && entity.path.endsWith('.yaml')) entity.path,
        ]..sort();
        for (final path in paths) {
          final relative = p.split(p.relative(path, from: lib)).join('/');
          files.add((
            name: 'package:$package/$relative',
            path: path,
            base: base,
          ));
        }
      } on FileSystemException catch (error) {
        unread.add(
          UnreadMigrations(
            file: 'package:$package/fix_data/',
            reason: fileErrorReason(error),
          ),
        );
      }
    }
    return files;
  }

  List<FixDataTransform> _read(
    _MigrationFile file,
    List<UnreadMigrations> unread,
  ) {
    final source = File(file.path);
    try {
      if (!source.existsSync()) return const [];
      return parseFixData(
        source.readAsStringSync(),
        file: file.name,
        base: file.base,
      );
    } on FileSystemException catch (error) {
      unread.add(
        UnreadMigrations(file: file.name, reason: fileErrorReason(error)),
      );
    } on FixDataFormatException catch (error) {
      unread.add(UnreadMigrations(file: file.name, reason: error.reason));
    } on FormatException catch (error) {
      unread.add(UnreadMigrations(file: file.name, reason: error.message));
    }
    return const [];
  }

  void _classify(
    FixDataTransform transform,
    Set<(String, String, MigrationStatus, String)> migrated,
    Set<(String, String?, String)> moved,
  ) {
    if (transform.library case final library?) {
      if (_imported.containsKey(library)) {
        moved.add((
          '$library',
          transform.newLibrary?.toString(),
          transform.title,
        ));
      }
      return;
    }
    final scope = [
      for (final uri in transform.uris)
        if (_imported[uri] case final library?) (uri, library),
    ];
    if (scope.isEmpty) return;
    final name = _migrationName(transform);
    final group = _group(scope.first.$1);
    // The migration counts because the project imports one of its libraries
    // (the scope). The element exists when ANY library the migration lists
    // exports it: `dart fix` accepts any of them.
    // - Exported by a library the project imports: it is in the namespace
    //   the walk covered, so it is classified below.
    // - Exported only by a listed library the project doesn't import (found
    //   through the libraries the analysis has loaded): it exists, so it is
    //   not removed, but the project can't reach it, so the delta leaves it
    //   out.
    // - Exported by none: removed.
    Element? target;
    for (final (_, library) in scope) {
      target = _lookUp(library, transform);
      if (target != null) break;
    }
    if (target == null) {
      for (final uri in transform.uris) {
        final library = _loaded[uri];
        if (library == null || _imported.containsKey(uri)) continue;
        if (_lookUp(library, transform) != null) return;
      }
      migrated.add((group, name, MigrationStatus.removed, transform.title));
      return;
    }
    final candidates = <Element>[
      target,
      if (target is ExecutableElement)
        for (final parameter in target.formalParameters)
          if (transform.oldParameters.contains(parameter.name)) parameter,
    ];
    var attached = false;
    for (final element in candidates) {
      if (!element.metadata.annotations.any((a) => a.isDeprecated)) continue;
      // The walk noted every deprecation the project can reach; one it did
      // not note is not the project's to list.
      for (final MapEntry(:key, :value) in _found.entries) {
        if (key.$1 != element) continue;
        value.migrations.add(transform.title);
        attached = true;
      }
    }
    if (!attached) {
      migrated.add((group, name, MigrationStatus.changed, transform.title));
    }
  }

  /// The element [transform] names, looked up in what [library] exports,
  /// or null when it is gone.
  Element? _lookUp(LibraryElement library, FixDataTransform transform) {
    final names = library.exportNamespace.definedNames2;
    final name = transform.name!;
    final container = transform.container;
    if (container == null) {
      // `dart fix` matches a top-level function, getter, setter, variable
      // or constant by use, not by the kind the migration names, so any of
      // them finds any of them; the exact kind wins when several exist.
      // Other kinds (classes and so on) look up as before.
      final top = transform.kind == 'setter'
          ? names['$name='] ?? names[name]
          : names[name] ?? names['$name='];
      return top == null ? null : _declared(top);
    }
    final owner = names[container];
    if (owner is! InstanceElement) return null;
    if (transform.kind == 'constructor') {
      if (owner is! InterfaceElement) return null;
      return owner.constructors
          .where((c) => name.isEmpty ? _isUnnamed(c.name) : c.name == name)
          .firstOrNull;
    }
    final types = <InstanceElement>[
      owner,
      if (owner is InterfaceElement)
        for (final supertype in owner.allSupertypes) supertype.element,
    ];
    // `dart fix` matches a property-style use against a migration of kind
    // constant, field, getter, method (a tear-off) or setter, so a member is
    // found under any of those kinds. The migration's own kind is tried
    // first within each type.
    final properties = <Element>[];
    final methods = <Element>[];
    final setters = <Element>[];
    for (final type in types) {
      properties
        ..clear()
        ..addAll(type.fields)
        ..addAll(type.getters);
      methods
        ..clear()
        ..addAll(type.methods);
      setters
        ..clear()
        ..addAll(type.setters);
      final order = switch (transform.kind) {
        'method' => [methods, properties, setters],
        'setter' => [setters, properties, methods],
        _ => [properties, methods, setters],
      };
      for (final members in order) {
        for (final member in members) {
          final memberName = member.name;
          if (memberName == null) continue;
          final plain = memberName.endsWith('=')
              ? memberName.substring(0, memberName.length - 1)
              : memberName;
          // A synthetic field, getter or setter stands for the declaration
          // that induced it, which is what carries the annotations.
          if (plain == name) return member.nonSynthetic;
        }
      }
    }
    return null;
  }
}

String _migrationName(FixDataTransform transform) {
  final name = transform.name!;
  final container = transform.container;
  if (container == null) {
    return transform.kind == 'setter' ? '$name=' : name;
  }
  return switch (transform.kind) {
    'constructor' => name.isEmpty ? '$container.new' : '$container.$name',
    'setter' => '$container.$name=',
    _ => '$container.$name',
  };
}

DeprecationKind _kindOf(ElementAnnotation annotation) {
  final element = annotation.element;
  if (element is! ConstructorElement) return DeprecationKind.use;
  return switch (element.name) {
    'implement' => DeprecationKind.implement,
    'extend' => DeprecationKind.extend,
    'subclass' => DeprecationKind.subclass,
    'instantiate' => DeprecationKind.instantiate,
    'mixin' => DeprecationKind.mixin,
    'optional' => DeprecationKind.optional,
    _ => DeprecationKind.use,
  };
}

/// The annotation's message on one line, or null. The `deprecated` constant
/// (`@deprecated`) says only "next release", so it counts as no message.
String? _messageOf(ElementAnnotation annotation) {
  if (annotation.element is! ConstructorElement) return null;
  final message = annotation
      .computeConstantValue()
      ?.getField('message')
      ?.toStringValue();
  if (message == null) return null;
  final oneLine = message.replaceAll(RegExp(r'\s+'), ' ').trim();
  return oneLine.isEmpty ? null : oneLine;
}

/// `dart:core` for `dart:core`, `package:flutter` for any library of the
/// flutter package.
String _group(Uri uri) => switch (uri.scheme) {
  'package' => 'package:${uri.pathSegments.first}',
  'dart' => 'dart:${uri.path.split('/').first}',
  _ => '$uri',
};

bool _isUnnamed(String? name) => name == null || name.isEmpty || name == 'new';

int _compare(List<int> results) =>
    results.firstWhere((result) => result != 0, orElse: () => 0);
