import 'package:appstein_protocol/appstein_protocol.dart';

import '../text/edit_distance.dart';
import 'tool_answer.dart';

/// `feature` (spec §8): everything in the feature [name] (its folder below
/// `lib/ui/`, such as `auth/login`; the folder itself, or the name wrapped
/// in slashes, works too), with the routes that build its screens.
///
/// An unknown name is refused, with the closest name and the list of
/// features.
ToolAnswer featureInfo(
  String name, {
  required FeaturesMap features,
  required RoutesMap routes,
}) {
  var wanted = name.trim().replaceAll(RegExp(r'^/+|/+$'), '');
  if (wanted.startsWith('lib/ui/')) wanted = wanted.substring('lib/ui/'.length);
  final feature = features.features[wanted];
  if (feature == null) {
    final names = features.features.keys.toList()..sort();
    final closest = closestMatch(wanted, names);
    return ToolRefusal(
      [
        'No feature is named "$name".',
        if (closest != null) 'Did you mean "$closest"?',
        if (names.isEmpty)
          'The project has no features.'
        else
          'The project has ${names.length} features: '
              '${names.take(20).join(', ')}${names.length > 20 ? ', …' : ''}.',
      ].join(' '),
    );
  }
  bool isScreen(CodeRef ref) => feature.screens.any(
    (screen) => screen.name == ref.name && screen.file == ref.file,
  );
  final featureRoutes = [
    for (final route in routes.routes)
      if (route.screen case final screen? when isScreen(screen))
        {
          'path': ?route.path,
          'file': route.file,
          'line': route.line,
          'screen': screen.name,
          if (route.unresolved) 'unresolved': true,
          'reason': ?route.reason,
        },
  ];
  String count(int n, String one, String many) => '$n ${n == 1 ? one : many}';
  return ToolReply(
    {'name': wanted, ...feature.toJson(), 'routes': featureRoutes},
    'Feature `$wanted` (${feature.folder}): '
    '${count(feature.screens.length, 'screen', 'screens')}, '
    '${count(feature.viewModels.length, 'view model', 'view models')}, '
    '${count(feature.repositories.length, 'repository', 'repositories')}, '
    '${count(feature.services.length, 'service', 'services')}, '
    '${count(feature.models.length, 'model', 'models')}, '
    '${count(featureRoutes.length, 'route', 'routes')}, '
    '${count(feature.tests.length, 'test', 'tests')}.',
  );
}
