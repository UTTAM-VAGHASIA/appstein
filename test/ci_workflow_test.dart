import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

// The `lost-jobs` job of ci.yml judges every other job of its attempt, so it
// must run after all of them: its `needs` list is written by hand, and a
// job added to ci.yml without it would end after lost-jobs had looked.
void main() {
  test('lost-jobs needs every other job of ci.yml', () {
    final workflow =
        loadYaml(File('.github/workflows/ci.yml').readAsStringSync())
            as YamlMap;
    final jobs = workflow['jobs'] as YamlMap;
    final lostJobs = jobs['lost-jobs'] as YamlMap;
    final needs = {...(lostJobs['needs'] as YamlList).cast<String>()};
    final others = {
      for (final name in jobs.keys.cast<String>())
        if (name != 'lost-jobs') name,
    };
    expect(
      others.difference(needs),
      isEmpty,
      reason: 'add these jobs to the needs of lost-jobs',
    );
    expect(lostJobs['if'], 'always()');
  });
}
