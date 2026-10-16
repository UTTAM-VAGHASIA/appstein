import 'package:appstein_cli/appstein_cli.dart';

Future<void> main(List<String> arguments) =>
    // Setting exitCode (instead of calling exit()) lets stdout finish flushing,
    // which matters on Windows consoles. runGuarded also turns an uncaught
    // async error into exit 3 (or, for a Claude Code hook, exit 0 with the
    // failure told in JSON).
    runGuarded(() => runAppstein(arguments), arguments: arguments);
