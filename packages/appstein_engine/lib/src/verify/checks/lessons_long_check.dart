import 'dart:convert';

import 'package:appstein_protocol/appstein_protocol.dart';

import '../../memory/memory_store.dart';
import '../verify_check.dart';

/// `memory.lessons_long` (spec §6.8): `.appstein/memory/lessons.md` has
/// more lines than an agent should read in full.
///
/// An info finding, so it never fails a run. Nothing is deleted or merged
/// automatically: which lessons belong together is for a person or the
/// agent to decide. A file that is missing or can't be read gives no
/// finding.
final class LessonsLongCheck implements VerifyCheck {
  /// Creates the check; more than [limit] lines is long.
  const LessonsLongCheck({this.limit = 200});

  /// The most lines `lessons.md` may have without a finding.
  final int limit;

  @override
  List<String> get ids => const ['memory.lessons_long'];

  @override
  VerifyMode get mode => VerifyMode.full;

  @override
  bool get needsMap => false;

  @override
  Future<List<Finding>> run(VerifyContext context) async {
    final bytes = readMemoryFile(
      memoryFile(context.projectRoot, memoryLessonsPath),
    ).bytes;
    if (bytes == null) return const [];
    final lines = const LineSplitter().convert(memoryText(bytes)).length;
    if (lines <= limit) return const [];
    return [
      Finding(
        id: ids.first,
        severity: Severity.info,
        file: memoryLessonsPath,
        message:
            'lessons.md has $lines lines; over $limit, it is slow to read '
            'in full.',
        fixHint:
            'Merge related lessons into fewer lines. Nothing is deleted '
            'automatically.',
      ),
    ];
  }
}
