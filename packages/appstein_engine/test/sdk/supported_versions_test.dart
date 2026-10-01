import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

void main() {
  test('the newest Flutter minor Appstein knows is the newest curated notes '
      'file', () {
    // Two constants name the same fact. When a new Flutter stable gets its
    // notes file, bump newestKnownFlutterMinor in supported_versions.dart.
    expect(newestKnownFlutterMinor, CuratedNotes.bundled().newestMinor);
  });
}
