import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../support/temp.dart';

void main() {
  test('on Windows, variable names are case-insensitive', () {
    final env = fakeEnvironment({'Path': r'C:\bin'}, os: HostOs.windows);
    expect(env.variable('PATH'), r'C:\bin');
  });

  test('elsewhere, variable names are case-sensitive', () {
    final env = fakeEnvironment({'Path': '/bin'}, os: HostOs.linux);
    expect(env.variable('PATH'), isNull);
  });

  test('an empty variable counts as unset', () {
    final env = fakeEnvironment({'JAVA_HOME': ''}, os: HostOs.linux);
    expect(env.variable('JAVA_HOME'), isNull);
  });

  test('Windows PATH entries lose quotes and empty parts', () {
    final env = fakeEnvironment({
      'PATH': r'C:\a;;"C:\Program Files\b";  ;',
    }, os: HostOs.windows);
    expect(env.pathEntries, [r'C:\a', r'C:\Program Files\b']);
  });

  test('POSIX PATH entries split on colons', () {
    final env = fakeEnvironment({'PATH': '/usr/bin::/opt/x'}, os: HostOs.linux);
    expect(env.pathEntries, ['/usr/bin', '/opt/x']);
  });

  test('home comes from USERPROFILE on Windows and HOME elsewhere', () {
    expect(
      fakeEnvironment({
        'USERPROFILE': r'C:\Users\a',
      }, os: HostOs.windows).homeDir,
      r'C:\Users\a',
    );
    expect(
      fakeEnvironment({'HOME': '/home/a'}, os: HostOs.linux).homeDir,
      '/home/a',
    );
  });
}
