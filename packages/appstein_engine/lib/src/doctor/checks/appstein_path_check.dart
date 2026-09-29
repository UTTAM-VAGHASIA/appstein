import 'package:path/path.dart' as p;

import '../../host/executable_finder.dart';
import '../../host/host_environment.dart';
import '../../host/process_runner.dart';
import '../doctor_check.dart';

/// Checks that agent hooks can find the `appstein` command (spec §5.3).
final class AppsteinPathCheck implements DoctorCheck {
  /// Creates the check.
  const AppsteinPathCheck();

  @override
  String get id => 'doctor.appstein_path';

  @override
  String get title => 'appstein on PATH';

  @override
  Future<CheckResult> run(DoctorContext context) async {
    final environment = context.environment;
    final current = findExecutable('appstein', environment);
    if (current == null) {
      return const CheckResult.warning(
        '`appstein` is not on PATH. Agent hooks call it by name, so they '
        'would fail.',
        fixHint:
            'Add the folder that contains the appstein executable to '
            'your PATH, then restart your terminal and your agent.',
      );
    }
    final details = ['Path: $current'];
    if (isPubSnapshot(current, environment)) {
      return CheckResult.warning(
        '`appstein` runs through a pub snapshot, which starts slowly. '
        'Hooks run it after every edit.',
        details: details,
        fixHint: 'Install the standalone binary from the GitHub release.',
      );
    }
    if (environment.os == HostOs.windows) {
      final saved = await savedWindowsPath(context.runner, environment);
      final folder = p.dirname(current);
      if (saved != null && !saved.any((dir) => p.equals(dir, folder))) {
        return CheckResult.warning(
          '`appstein` is on this terminal\'s PATH, but not on your saved user '
          'or system PATH, so an agent started from elsewhere won\'t find it.',
          details: details,
          fixHint:
              'Add $folder to your user PATH (Settings > System > About > '
              'Advanced system settings > Environment Variables), then '
              'restart the agent.',
        );
      }
    }
    return CheckResult.ok('appstein is on PATH', details: details);
  }
}

/// Whether [path] is a `dart pub global activate` launcher:
/// `%LOCALAPPDATA%\Pub\Cache\bin` on Windows, `~/.pub-cache/bin` elsewhere,
/// or anywhere under PUB_CACHE.
bool isPubSnapshot(String path, HostEnvironment environment) {
  final pubCache = environment.variable('PUB_CACHE');
  if (pubCache != null && p.isWithin(pubCache, path)) return true;
  final parts = p.split(p.dirname(path)).map((s) => s.toLowerCase()).toList();
  final n = parts.length;
  if (n < 2 || parts[n - 1] != 'bin') return false;
  return parts[n - 2] == '.pub-cache' ||
      (n >= 3 && parts[n - 2] == 'cache' && parts[n - 3] == 'pub');
}

/// The data of the `Path` value in `reg query ... /v Path` output.
String? parseRegPathValue(String output) => RegExp(
  r'^\s*Path\s+REG_(?:EXPAND_)?SZ\s+(.*)$',
  multiLine: true,
  caseSensitive: false,
).firstMatch(output)?.group(1)?.trim();

/// Expands `%NAME%` references with [environment], leaving unknown ones.
String expandWindowsVariables(String value, HostEnvironment environment) =>
    value.replaceAllMapped(
      RegExp('%([^%]+)%'),
      (m) => environment.variable(m.group(1)!) ?? m.group(0)!,
    );

/// The user and system PATH saved in the Windows registry, with `%NAME%`
/// references expanded. Programs started from now on get this PATH. Null
/// when neither can be read.
Future<List<String>?> savedWindowsPath(
  ProcessRunner runner,
  HostEnvironment environment,
) async {
  const keys = [
    r'HKCU\Environment',
    r'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Environment',
  ];
  final dirs = <String>[];
  var readAny = false;
  for (final key in keys) {
    final result = await runner.run('reg', ['query', key, '/v', 'Path']);
    final value = result.ok ? parseRegPathValue(result.stdout) : null;
    if (value == null) continue;
    readAny = true;
    for (final entry in value.split(';')) {
      final dir = expandWindowsVariables(entry.trim(), environment);
      if (dir.isNotEmpty) dirs.add(dir);
    }
  }
  return readAny ? dirs : null;
}
