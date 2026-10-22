import 'package:appstein_engine/appstein_engine.dart';
import 'package:test/test.dart';

import '../tool/src/host_folder_choice.dart';

// The measurement of the host folder choice (slice 1d.7, ticket 14), with a
// scripted choice: what it prints, and when it fails the run.
void main() {
  HostFolderChoiceResult scripted(
    HostOs os,
    AnalysisHostPlaceKind kind,
    List<int> processes,
  ) {
    var i = 0;
    return measureHostFolderChoice(
      projectRoot: '/work/app',
      os: os,
      choices: processes.length,
      choose: () => (kind: kind, processes: processes[i++]),
    );
  }

  test('it makes 21 choices by default and prints the kind, the first time, '
      'the median of the others and the processes of each', () {
    var calls = 0;
    final result = measureHostFolderChoice(
      projectRoot: '/work/app',
      os: HostOs.windows,
      choose: () {
        calls++;
        return (kind: AnalysisHostPlaceKind.localAppData, processes: 0);
      },
    );
    expect(calls, 21);
    expect(result.others, hasLength(20));
    expect(result.problem, isNull);
    final table = result.table();
    expect(table, contains('| Place chosen | localAppData |'));
    expect(table, contains('First choice'));
    expect(table, contains('Median of the other 20'));
    expect(table, contains('| 0 at most ('));
    expect(table, contains('windows'));
  });

  test('a Windows choice that starts a process fails the run', () {
    expect(
      scripted(HostOs.windows, AnalysisHostPlaceKind.dartTool, [
        0,
        1,
        0,
      ]).problem,
      contains('on Windows started 1 process(es)'),
    );
  });

  test("a macOS choice in the user's temporary folder that starts a process "
      'fails the run; one in Library/Caches may start its stat', () {
    expect(
      scripted(HostOs.macos, AnalysisHostPlaceKind.userTemp, [1, 0]).problem,
      contains("macOS's temporary folder started 1"),
    );
    expect(
      scripted(HostOs.macos, AnalysisHostPlaceKind.cache, [1, 1]).problem,
      isNull,
    );
  });

  test('Linux is reported, never failed', () {
    final result = scripted(HostOs.linux, AnalysisHostPlaceKind.cache, [
      1,
      1,
      1,
    ]);
    expect(result.problem, isNull);
    expect(result.table(), contains('| 1 at most (1, 1, 1) |'));
  });

  test('choices that give different kinds say so', () {
    var i = 0;
    expect(
      measureHostFolderChoice(
        projectRoot: '/work/app',
        os: HostOs.linux,
        choices: 2,
        choose: () => (
          kind: i++ == 0
              ? AnalysisHostPlaceKind.cache
              : AnalysisHostPlaceKind.runUser,
          processes: 1,
        ),
      ).kind,
      isNull,
    );
  });

  test('the real choice on this machine', () {
    final result = measureHostFolderChoice(projectRoot: '/work/app');
    // Printed for the report.
    // ignore: avoid_print
    print(result.table());
    expect(result.problem, isNull);
  });
}
