import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../host/file_errors.dart';
import '../knowledge/knowledge_lock.dart';
import '../knowledge/knowledge_store.dart';
import '../knowledge/knowledge_write_exception.dart';
import '../memory/memory_store.dart';
import 'tool_answer.dart';

/// The `memory_read` tool (spec §6.8, §8): the task in progress and the
/// [newest] lessons of the project at [projectRoot], with a count of the
/// older ones.
///
/// It never refuses: a file that can't be read is named in the reply.
ToolAnswer memoryRead(String projectRoot, {int newest = 50}) {
  final current = readMemoryFile(memoryFile(projectRoot, memoryCurrentPath));
  final lessonsFile = readMemoryFile(
    memoryFile(projectRoot, memoryLessonsPath),
  );
  final task = switch (current.bytes) {
    final bytes? when memoryText(bytes).trim().isNotEmpty => memoryText(bytes),
    _ => null,
  };
  final all = switch (lessonsFile.bytes) {
    final bytes? => lessonsIn(memoryText(bytes)),
    null => const <String>[],
  };
  final older = all.length > newest ? all.length - newest : 0;
  return ToolReply(
    {
      'current': ?task,
      'currentFile': memoryCurrentPath,
      'currentProblem': ?current.problem,
      'lessons': all.sublist(older),
      'olderLessons': older,
      'lessonsFile': memoryLessonsPath,
      'lessonsProblem': ?lessonsFile.problem,
    },
    [
      '${switch (task) {
            final task? => 'A task is in progress '
                '(${_lines(const LineSplitter().convert(task.trim()).length)})',
            null => 'No task is in progress',
          }}; '
          '${switch (all.length) {
            0 => 'no lessons recorded yet',
            1 => '1 lesson recorded',
            final count => '$count lessons recorded',
          }}.',
      if (older > 0)
        'The newest $newest are listed; the $older older '
            '${older == 1 ? 'one is' : 'ones are'} in $memoryLessonsPath.',
      if (current.problem case final problem?)
        '`$memoryCurrentPath` could not be read ($problem).',
      if (lessonsFile.problem case final problem?)
        '`$memoryLessonsPath` could not be read ($problem).',
    ].join(' '),
  );
}

String _lines(int count) => count == 1 ? '1 line' : '$count lines';

/// The `memory_write` tool (spec §6.8, §8), on the project at
/// [projectRoot], holding the `.appstein/` write lock (spec §15).
///
/// `kind: current` replaces the task in progress with `text`; `lesson`
/// appends `text` to the lessons as one line dated [today]; `complete`
/// appends `text`, the agent's summary, as a lesson and deletes the task in
/// progress. Anything it can't do is a [ToolRefusal] that says what was and
/// wasn't written. [deleteFile] deletes the task in progress; tests pass
/// one that fails.
Future<ToolAnswer> memoryWrite(
  String projectRoot,
  Map<String, Object?> arguments, {
  required String today,
  Duration lockTimeout = const Duration(seconds: 10),
  void Function(File file)? deleteFile,
}) async {
  final kind = arguments['kind'];
  final text = switch (arguments['text']) {
    final String text => text,
    _ => '',
  };
  if (kind != 'current' && kind != 'lesson' && kind != 'complete') {
    return ToolRefusal(
      '`kind` is `current`, `lesson` or `complete`, not `$kind`.',
    );
  }
  if (text.trim().isEmpty) {
    return ToolRefusal(switch (kind) {
      'current' =>
        '`text` is empty. For kind: current give the goal, plan, status and '
            'open questions.',
      'lesson' =>
        '`text` is empty. For kind: lesson give the lesson in one line.',
      _ =>
        'Give your one-paragraph summary of the finished task as `text`. '
            'Nothing was cleared.',
    });
  }

  final KnowledgeLock lock;
  try {
    lock = await KnowledgeLock.acquire(
      p.join(projectRoot, '.appstein'),
      timeout: lockTimeout,
    );
  } on KnowledgeLockTimeout catch (error) {
    return ToolRefusal('$error');
  } on KnowledgeWriteException catch (error) {
    return ToolRefusal('$error');
  }
  try {
    return switch (kind) {
      'current' => await _current(projectRoot, text),
      'lesson' => await _lesson(projectRoot, text, today),
      _ => await _complete(
        projectRoot,
        text,
        today,
        deleteFile ?? (file) => file.deleteSync(),
      ),
    };
  } on KnowledgeWriteException catch (error) {
    return ToolRefusal('$error');
  } finally {
    lock.release();
  }
}

Future<ToolAnswer> _current(String projectRoot, String text) async {
  final task = text.trim();
  await replaceFile(memoryFile(projectRoot, memoryCurrentPath).path, '$task\n');
  return ToolReply(
    {'kind': 'current', 'file': memoryCurrentPath},
    'The task in progress is saved in $memoryCurrentPath '
    '(${_lines(const LineSplitter().convert(task).length)}).',
  );
}

/// Appends the lesson [text] and says whether it was new; a refusal when
/// `lessons.md` can't be read.
Future<({String line, bool added, ToolRefusal? refusal})> _append(
  String projectRoot,
  String text,
  String today,
) async {
  final line = lessonLine(today, text);
  final file = memoryFile(projectRoot, memoryLessonsPath);
  final read = readMemoryFile(file);
  if (read.problem case final problem?) {
    return (
      line: line,
      added: false,
      refusal: ToolRefusal(
        '`$memoryLessonsPath` could not be read ($problem), so the lesson '
        'was not added.',
      ),
    );
  }
  final bytes = withLesson(read.bytes, line);
  if (bytes != null) await replaceFileBytes(file.path, bytes);
  return (line: line, added: bytes != null, refusal: null);
}

Future<ToolAnswer> _lesson(
  String projectRoot,
  String text,
  String today,
) async {
  final (:line, :added, :refusal) = await _append(projectRoot, text, today);
  if (refusal != null) return refusal;
  return ToolReply(
    {
      'kind': 'lesson',
      'file': memoryLessonsPath,
      'lesson': line,
      'added': added,
    },
    added
        ? 'Added the lesson to $memoryLessonsPath.'
        : 'That lesson is already in $memoryLessonsPath; nothing was added.',
  );
}

Future<ToolAnswer> _complete(
  String projectRoot,
  String text,
  String today,
  void Function(File file) deleteFile,
) async {
  final current = memoryFile(projectRoot, memoryCurrentPath);
  final task = readMemoryFile(current);
  if (task.problem case final problem?) {
    return ToolRefusal(
      '`$memoryCurrentPath` could not be read ($problem). Nothing was '
      'changed.',
    );
  }
  if (task.bytes == null || memoryText(task.bytes!).trim().isEmpty) {
    return const ToolRefusal(
      'No task is in progress, so there is nothing to finish. Use kind: '
      'lesson to record a lesson.',
    );
  }
  // The lesson first: if deleting fails, the summary is not lost, and
  // calling again adds nothing twice.
  final (:line, :added, :refusal) = await _append(projectRoot, text, today);
  if (refusal != null) return refusal;
  try {
    deleteFile(current);
  } on FileSystemException catch (error) {
    return ToolRefusal(
      'The summary is saved as a lesson in $memoryLessonsPath, but '
      "$memoryCurrentPath couldn't be deleted (${fileErrorReason(error)}). "
      'Close any program that has it open, then call memory_write with '
      'kind: complete again.',
    );
  }
  return ToolReply(
    {
      'kind': 'complete',
      'file': memoryLessonsPath,
      'lesson': line,
      'added': added,
      'cleared': memoryCurrentPath,
    },
    'The task is finished: its summary is a lesson in $memoryLessonsPath, '
    'and $memoryCurrentPath was deleted.',
  );
}
