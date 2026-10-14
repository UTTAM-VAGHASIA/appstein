import 'package:appstein_protocol/appstein_protocol.dart';

import '../verify_check.dart';

/// `dart.unreadable`: a Dart file the analysis covers that could not be
/// read is an error on that file, in fast and full runs (owner's decision of
/// 2026-10-14, slice 1d.2).
///
/// On Windows the analysis server lists a file another program holds locked
/// as analyzed, with no diagnostic, so every code check would read it as
/// clean, `dart.error` included. Before each reading Appstein looks at every
/// Dart file (`DiskLook`), and opens each one there: a file it can't open
/// and read is in `CodeReading.unreadableFiles`. Such a file also never
/// leaves the unverified files.
final class DartUnreadableCheck implements GatheringCheck {
  /// Creates the check.
  const DartUnreadableCheck();

  @override
  List<String> get ids => const ['dart.unreadable'];

  @override
  VerifyMode get mode => VerifyMode.fast;

  @override
  bool get needsMap => false;

  @override
  Future<void> gather(VerifyGathering gathering) => gathering.code();

  @override
  Future<List<Finding>> run(VerifyContext context) async => [
    for (final MapEntry(key: file, value: reason)
        in context.code.unreadableFiles.entries)
      Finding(
        id: 'dart.unreadable',
        severity: Severity.error,
        file: file,
        message:
            'This file could not be read (${_plain(reason)}), so nothing in '
            'it was checked.',
        fixHint:
            'Close the program that holds the file open, or wait until it '
            'has finished writing it, then run `appstein verify` again.',
      ),
  ];
}

/// [text] as part of a sentence: one line, without a closing full stop.
String _plain(String text) => text
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim()
    .replaceFirst(RegExp(r'\.$'), '');
