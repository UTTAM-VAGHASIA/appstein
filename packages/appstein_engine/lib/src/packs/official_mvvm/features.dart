import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:appstein_protocol/appstein_protocol.dart';

import '../../map/project_analysis.dart';

/// Builds `features.json` for the official_mvvm layout (spec §6.5).
///
/// A feature is a folder under `lib/ui/` (except `core/`) that has a
/// `view_models/` or `widgets/` folder. Its name is its path below
/// `lib/ui/`. A file belongs to the deepest feature folder that holds it,
/// and its tests are under `test/ui/<feature>/`. Screens come from
/// [routes]; [matcher] sorts the view models' constructor types into
/// repositories and services and finds the `domain` files the feature
/// imports.
FeaturesMap readFeatures(
  ProjectAnalysis analysis, {
  required RoutesMap routes,
  required LayerMatcher matcher,
}) {
  final libFiles = <String>[];
  final testFiles = <String>[];
  // Each file's units, so a feature reads only its own files.
  final unitsByFile = <String, List<ResolvedUnitResult>>{};
  for (final library in analysis.libraries) {
    for (final unit in library.result.units) {
      final file = analysis.relativePath(unit.path);
      if (file == null) continue;
      (unitsByFile[file] ??= []).add(unit);
      if (file.startsWith('lib/ui/')) libFiles.add(file);
      if (file.startsWith('test/ui/')) testFiles.add(file);
    }
  }
  final names = {for (final file in libFiles) ?_featureName(file)};

  String? owner(String file, String root) {
    String? best;
    for (final name in names) {
      if (file.startsWith('$root/$name/') &&
          (best == null || name.length > best.length)) {
        best = name;
      }
    }
    return best;
  }

  // Each file's feature, found once: asking per feature made this cubic.
  final filesOf = <String, List<String>>{};
  for (final file in libFiles) {
    if (owner(file, 'lib/ui') case final name?) {
      (filesOf[name] ??= []).add(file);
    }
  }
  final testsOf = <String, List<String>>{};
  for (final file in testFiles) {
    if (owner(file, 'test/ui') case final name?) {
      (testsOf[name] ??= []).add(file);
    }
  }
  // Every class of the project with its file, in library order.
  final classes = <(ClassElement, String)>[];
  for (final library in analysis.libraries) {
    for (final element in library.result.element.classes) {
      if (analysis.locationOf(element.firstFragment) case final location?) {
        classes.add((element, location.file));
      }
    }
  }

  CodeRef? refOf(Element element) {
    final name = element.name;
    final location = analysis.locationOf(element.firstFragment);
    if (name == null || location == null) return null;
    return CodeRef(name: name, file: location.file);
  }

  final features = <String, Feature>{};
  for (final name in names.toList()..sort()) {
    final files = [...?filesOf[name]]..sort();
    final fileSet = files.toSet();
    final tests = [...?testsOf[name]]..sort();

    final viewModels = [
      for (final (element, file) in classes)
        if (fileSet.contains(file) &&
            file.startsWith('lib/ui/$name/view_models/') &&
            _isViewModel(element))
          element,
    ];

    final repositories = <CodeRef>[];
    final services = <CodeRef>[];
    for (final viewModel in viewModels) {
      for (final constructor in viewModel.constructors) {
        for (final parameter in constructor.formalParameters) {
          final type = parameter.type;
          if (type is! InterfaceType) continue;
          final ref = refOf(type.element);
          if (ref == null) continue;
          switch (matcher.tagFor(ref.file)) {
            case 'data.repository':
              repositories.add(ref);
            case 'data.service':
              services.add(ref);
          }
        }
      }
    }

    final models = <CodeRef>[];
    for (final file in files) {
      for (final unit in unitsByFile[file] ?? const <ResolvedUnitResult>[]) {
        for (final import in analysis.importsOf(unit)) {
          // Use cases are domain code, but not data the feature uses (P4).
          if (matcher.tagFor(import.file) != 'domain' ||
              import.file.startsWith('lib/domain/use_cases/')) {
            continue;
          }
          for (final element in import.library.classes) {
            if (!element.isPublic) continue;
            if (refOf(element) case final ref?) models.add(ref);
          }
        }
      }
    }

    final screens = [
      for (final route in routes.routes)
        if (route.screen case final screen?
            when fileSet.contains(screen.file) &&
                screen.file.startsWith('lib/ui/$name/widgets/'))
          screen,
    ];

    features[name] = Feature(
      folder: 'lib/ui/$name',
      viewModels: _sorted([for (final element in viewModels) ?refOf(element)]),
      screens: _sorted(screens),
      repositories: _sorted(repositories),
      services: _sorted(services),
      models: _sorted(models),
      tests: tests,
      files: files,
    );
  }
  return FeaturesMap(features: features);
}

/// The feature [file] sits in: the path below `lib/ui/` up to the first
/// `view_models` or `widgets` folder. Null for `lib/ui/core/`, and for files
/// with no feature folder.
String? _featureName(String file) {
  final segments = file.split('/');
  final marker = segments.indexWhere(
    (segment) => segment == 'view_models' || segment == 'widgets',
    2,
  );
  if (marker <= 2 || segments[2] == 'core') return null;
  return segments.sublist(2, marker).join('/');
}

/// Whether [element] is a view model: a concrete class that extends
/// Flutter's `ChangeNotifier`, directly or through other classes. Abstract
/// base classes don't count (P3).
bool _isViewModel(ClassElement element) =>
    !element.isAbstract &&
    element.allSupertypes.any((type) {
      final uri = type.element.library.uri;
      return type.element.name == 'ChangeNotifier' &&
          uri.scheme == 'package' &&
          uri.pathSegments.isNotEmpty &&
          uri.pathSegments.first == 'flutter';
    });

/// [refs] without duplicates, sorted by name, then file.
List<CodeRef> _sorted(Iterable<CodeRef> refs) {
  final unique = {for (final ref in refs) '${ref.name}\n${ref.file}': ref};
  return unique.values.toList()..sort((a, b) {
    final byName = a.name.compareTo(b.name);
    return byName != 0 ? byName : a.file.compareTo(b.file);
  });
}
