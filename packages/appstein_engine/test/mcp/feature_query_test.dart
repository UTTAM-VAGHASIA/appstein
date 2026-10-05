import 'package:appstein_engine/appstein_engine.dart';
import 'package:appstein_protocol/appstein_protocol.dart';
import 'package:test/test.dart';

import 'support/mcp_support.dart';

void main() {
  final features = FeaturesMap.fromJson(golden('features.json'));
  final routes = RoutesMap.fromJson(golden('routes.json'));

  ToolAnswer ask(String name) =>
      featureInfo(name, features: features, routes: routes);

  test('a feature with its screens, view models and routes', () {
    final reply = ask('auth/login') as ToolReply;
    expect(reply.result['name'], 'auth/login');
    expect(reply.result['folder'], 'lib/ui/auth/login');
    expect(reply.result['screens'], [
      {
        'name': 'LoginScreen',
        'file': 'lib/ui/auth/login/widgets/login_screen.dart',
      },
    ]);
    expect(reply.result['routes'], [
      {
        'path': '/login',
        'file': 'lib/routing/router.dart',
        'line': 22,
        'screen': 'LoginScreen',
      },
    ]);
    expect(
      reply.summary,
      'Feature `auth/login` (lib/ui/auth/login): 1 screen, 1 view model, 1 '
      'repository, 0 services, 0 models, 1 route, 0 tests.',
    );
    expectMatchesSchema(ToolSchemas.featureResult, withoutNulls(reply.result));
  });

  test('a route whose path is unresolved is listed with its reason', () {
    final reply = ask('settings') as ToolReply;
    final listed = (reply.result['routes']! as List)
        .cast<Map<String, Object?>>();
    expect(listed.single['unresolved'], isTrue);
    expect(listed.single['reason'], 'the path is not a constant string');
    expect(listed.single['screen'], 'SettingsScreen');
    expect(listed.single.containsKey('path'), isFalse);
  });

  test('the folder or a slash-wrapped name finds the feature', () {
    expect((ask('lib/ui/booking') as ToolReply).result['name'], 'booking');
    expect((ask('/home/') as ToolReply).result['name'], 'home');
  });

  test('an unknown name suggests the closest and lists the features', () {
    expect(
      (ask('bookng') as ToolRefusal).message,
      'No feature is named "bookng". Did you mean "booking"? The project '
      'has 5 features: auth/login, booking, home, profile, settings.',
    );
  });
}
