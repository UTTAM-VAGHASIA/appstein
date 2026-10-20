import 'package:test/test.dart';

import '../tool/src/measure_context.dart';

void main() {
  const context = MeasureContext(
    executable: '/work/appstein',
    project: '/work/app',
    flutterRoot: '/sdk',
    hostFolder: '/work/hosts',
  );

  test('every process gets the Flutter SDK and a host folder of its own', () {
    expect(context.environment(), {
      'FLUTTER_ROOT': '/sdk',
      'APPSTEIN_ANALYSIS_HOST_FOLDER': '/work/hosts',
    });
  });

  test('a cache folder moves the analysis server\'s disk cache', () {
    expect(context.environment('/work/cache'), {
      'FLUTTER_ROOT': '/sdk',
      'APPSTEIN_ANALYSIS_HOST_FOLDER': '/work/hosts',
      'ANALYZER_STATE_LOCATION_OVERRIDE': '/work/cache',
    });
  });
}
