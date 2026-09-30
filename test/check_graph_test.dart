import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/graphify.dart';
import 'support/temp_repo.dart';

final _script = p.absolute('tool', 'check_graph.py');
final _fixture = p.absolute('test', 'support', 'graphify_fixture.py');

const _update = 'Run /graphify . --update before relying on it.';
const _usage =
    'usage: check_graph.py [--quiet] [--skip-repairable] | --repair | '
    '--detach | --after-rebuild';

/// Holds graphify's rebuild lock for `argv[1]` seconds, as a running
/// rebuild does, and says when it has it and when it let go.
const _holdLock = '''
import sys, time
from pathlib import Path
from graphify.watch import _rebuild_lock
with _rebuild_lock(Path('graphify-out'), blocking=True):
    print('held', flush=True)
    time.sleep(float(sys.argv[1]))
print('released', flush=True)
''';

/// The id graphify gives [doc]'s own heading node, as graphify_fixture.py
/// computes it.
String _docId(String doc) => doc
    .replaceFirst(RegExp(r'\.[^./]*$'), '')
    .toLowerCase()
    .replaceAll(RegExp('[^0-9a-z]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

void main() {
  late String python;
  late Directory repo;

  /// The environment for graphify's Python: without the caller's
  /// `GRAPHIFY_OUT`, `PYTHONPATH`, `PYTHONHASHSEED` or
  /// `GRAPHIFY_REBUILD_LOG`, which would move the graph, shadow graphify,
  /// skip the script's own seeding or write to the caller's log.
  Map<String, String> environment(Map<String, String> extra) => {
    for (final entry in Platform.environment.entries)
      if (!const {
        'GRAPHIFY_OUT',
        'PYTHONPATH',
        'PYTHONHASHSEED',
        'GRAPHIFY_REBUILD_LOG',
      }.contains(entry.key.toUpperCase()))
        entry.key: entry.value,
    ...extra,
  };

  /// Runs graphify's Python in [repo].
  ProcessResult runPython(
    List<String> arguments, {
    Map<String, String> extra = const {},
  }) => Process.runSync(
    python,
    arguments,
    workingDirectory: repo.path,
    environment: environment(extra),
    includeParentEnvironment: false,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );

  /// Starts graphify's Python in [repo], for a test that runs it alongside
  /// something else.
  Future<Process> startPython(
    List<String> arguments, {
    Map<String, String> extra = const {},
  }) => Process.start(
    python,
    arguments,
    workingDirectory: repo.path,
    environment: environment(extra),
    includeParentEnvironment: false,
  );

  /// Fakes `/graphify . --update` extracting [docs] with [prompt].
  void extract(
    String prompt,
    List<String> docs, {
    List<String> flags = const [],
  }) {
    final result = runPython([_fixture, prompt, ...flags, ...docs]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  /// Writes a graph.json with the concept node the fixture extracts from
  /// each of [docs] (its source written as in [sources], if given), and
  /// [more] nodes.
  void graph(
    List<String> docs, {
    Map<String, String> sources = const {},
    List<Map<String, String>> more = const [],
  }) => writeFile(
    repo,
    'graphify-out/graph.json',
    jsonEncode({
      'nodes': [
        for (final doc in docs)
          {'id': '${_docId(doc)}_concept', 'source_file': sources[doc] ?? doc},
        ...more,
      ],
      'links': <Object>[],
    }),
  );

  /// Runs the script with [arguments] and returns its exit code and what it
  /// printed, with Windows line endings as `\n`.
  ({int code, String output}) check([
    List<String> arguments = const [],
    Map<String, String> extra = const {},
  ]) {
    final result = runPython([_script, ...arguments], extra: extra);
    return (
      code: result.exitCode,
      output: '${result.stdout}${result.stderr}'
          .replaceAll('\r\n', '\n')
          .trim(),
    );
  }

  setUp(() {
    python =
        graphifyPython ??
        fail(
          'APPSTEIN_REQUIRE_GRAPHIFY=1, but no Python with graphify was found',
        );
    repo = tempRepo();
    writeFile(repo, '.gitignore', 'graphify-out/\n');
    writeFile(repo, 'docs/a.md', '# A\n\nalpha\n');
    writeFile(repo, 'docs/b.md', '# B\n\nbeta\n');
    writeFile(repo, 'lib/c.dart', 'void main() {}\n');
  });

  group('with graphify', skip: skipWithoutGraphify, () {
    void upToDate() {
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      graph(['docs/a.md', 'docs/b.md', 'lib/c.dart']);
    }

    test('says the graph is current, or nothing with --quiet', () {
      upToDate();
      expect(check(), (
        code: 0,
        output: 'graphify: the graph is current (2 docs checked).',
      ));
      expect(check(['--quiet']), (code: 0, output: ''));
    });

    test('names a changed doc and a new doc', () {
      upToDate();
      writeFile(repo, 'docs/b.md', '# B\n\nbeta, changed\n');
      writeFile(repo, 'docs/n.md', '# N\n\nnew\n');
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 2 docs (new or changed: '
            'docs/b.md, docs/n.md). $_update',
      ));
    });

    test('counts an extraction made with any prompt', () {
      upToDate();
      writeFile(repo, 'docs/b.md', '# B\n\nbeta, changed\n');
      extract('another agent prompt', ['docs/b.md']);
      expect(check().code, 0);
    });

    test('counts a deep-mode extraction', () {
      extract('prompt one', ['docs/a.md']);
      extract('prompt one', ['docs/b.md'], flags: ['--deep']);
      graph(['docs/a.md', 'docs/b.md']);
      expect(check().code, 0);
    });

    test('treats a partial extraction as missing', () {
      extract('prompt one', ['docs/a.md']);
      extract('prompt one', ['docs/b.md'], flags: ['--partial']);
      graph(['docs/a.md', 'docs/b.md']);
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 1 doc (new or changed: '
            'docs/b.md). $_update',
      ));
    });

    test('names a doc that is extracted but missing from the graph', () {
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      graph(['docs/a.md']);
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 1 doc (missing from the graph: '
            'docs/b.md). $_update',
      ));
    });

    test("doesn't count graphify's heading node as the doc's extraction", () {
      // A code rebuild adds heading nodes for a Markdown doc, one with the
      // id the extraction gives the doc itself.
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      graph(
        ['docs/a.md'],
        more: [
          {'id': 'docs_b', 'source_file': 'docs/b.md', '_origin': 'ast'},
        ],
      );
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 1 doc (missing from the graph: '
            'docs/b.md). $_update',
      ));
    });

    test('counts a doc whose extraction is only its heading node as in the '
        'graph', () {
      // Nothing could be put back: the heading node wins.
      extract('prompt one', ['docs/a.md'], flags: ['--only-heading']);
      extract('prompt one', ['docs/b.md']);
      graph(
        ['docs/b.md'],
        more: [
          {'id': 'docs_a', 'source_file': 'docs/a.md', '_origin': 'ast'},
        ],
      );
      expect(check().code, 0);
    });

    test('names a deleted doc still in the graph, but not a deleted code '
        'file', () {
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      graph(['docs/a.md', 'docs/b.md', 'docs/old.md', 'lib/gone.dart']);
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 1 doc (deleted or no longer '
            'scanned: docs/old.md). $_update',
      ));
    });

    test('matches graph paths written with backslashes or as absolute '
        'paths', () {
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      graph(
        ['docs/a.md', 'docs/b.md'],
        sources: {
          'docs/a.md': r'docs\a.md',
          'docs/b.md': p.join(repo.path, 'docs', 'b.md'),
        },
      );
      expect(check().code, 0);
    });

    test('lists at most five names per reason', () {
      upToDate();
      for (var i = 0; i < 7; i++) {
        writeFile(repo, 'docs/m$i.md', '# M$i\n');
      }
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 7 docs (new or changed: '
            'docs/m0.md, docs/m1.md, docs/m2.md, docs/m3.md, docs/m4.md and '
            '2 more). $_update',
      ));
    });

    test('with --skip-repairable, says docs missing from the graph are '
        'being repaired, and warns only about the rest', () {
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      graph(['docs/a.md']);
      const repairing =
          'graphify: repairing 1 doc from the cache in the background '
          '(docs/b.md).';
      expect(check(['--quiet', '--skip-repairable']), (
        code: 0,
        output: repairing,
      ));
      writeFile(repo, 'docs/n.md', '# N\n\nnew\n');
      expect(check(['--quiet', '--skip-repairable']), (
        code: 1,
        output:
            '$repairing\ngraphify: the graph is behind on 1 doc (new or '
            'changed: docs/n.md). $_update',
      ));
    });

    test('cannot run without a graph, and says so in UTF-8', () {
      final result = check();
      expect(result.code, 3);
      expect(
        result.output,
        startsWith(
          'graphify: the graph check could not run: there is no graph yet',
        ),
      );
      // The temp repo's path contains "tëst"; on Windows this fails unless
      // the script prints UTF-8.
      expect(result.output, contains('tëst'));
    });

    test("cannot run when graphify doesn't have what it calls", () {
      upToDate();
      // A fake, empty graphify package that shadows the real one, as a
      // graphify release that moved its functions would.
      writeFile(repo, 'fake/graphify/__init__.py', '');
      final fake = {'PYTHONPATH': p.join(repo.path, 'fake')};
      final checked = check(const [], fake);
      expect(checked.code, 3);
      expect(
        checked.output,
        startsWith('graphify: the graph check could not run: '),
      );
      final repaired = check(['--repair'], fake);
      expect(repaired.code, 3);
      expect(
        repaired.output,
        startsWith('graphify: could not repair the graph: '),
      );
    });

    test('--repair without a graph fails before creating graphify-out', () {
      final result = check(['--repair']);
      expect(result.code, 3);
      expect(
        result.output,
        startsWith(
          'graphify: could not repair the graph: there is no graph yet',
        ),
      );
      expect(
        Directory(p.join(repo.path, 'graphify-out')).existsSync(),
        isFalse,
      );
    });

    test('rejects an unknown argument, or two modes at once', () {
      expect(check(['--nope']), (
        code: 3,
        output: '$_usage (not understood: --nope)',
      ));
      expect(check(['--repair', '--quiet']), (
        code: 3,
        output: '$_usage (not understood: --repair --quiet)',
      ));
    });
  });

  group('repair, with graphify', skip: skipWithoutGraphify, () {
    /// Runs graphify's own code rebuild, as its git hooks do.
    void build() {
      final result = runPython([_fixture, '--build']);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    }

    Map<String, Object?> loadGraph() =>
        jsonDecode(
              File(
                p.join(repo.path, 'graphify-out', 'graph.json'),
              ).readAsStringSync(),
            )
            as Map<String, Object?>;

    List<Map<String, Object?>> nodes() => [
      for (final node in loadGraph()['nodes']! as List)
        node as Map<String, Object?>,
    ];

    Set<String> nodeIds() => {
      for (final node in nodes()) node['id']! as String,
    };

    /// Rebuilds the graph while docs/b.md is gone, as on a branch without
    /// it, then puts the same file back and rebuilds again, as a pull does.
    void dropB() {
      final b = File(p.join(repo.path, 'docs', 'b.md'));
      final text = b.readAsStringSync();
      b.deleteSync();
      build();
      b.writeAsStringSync(text);
      build();
    }

    /// Repairs, and expects both docs to be put back.
    void repairAll() => expect(check(['--repair']), (
      code: 0,
      output:
          'graphify: repaired 2 docs from the cache (docs/a.md, docs/b.md).',
    ));

    /// graphify's rebuild log, for the background repair, outside the repo.
    late File log;

    String logged() => log.existsSync() ? log.readAsStringSync() : '';

    setUp(() {
      log = File(p.join(tempFolder().path, 'rebuild log.txt'));
      extract('prompt one', ['docs/a.md', 'docs/b.md']);
      build();
    });

    test('puts cached docs into a graph built from code alone', () {
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 2 docs (missing from the graph: '
            'docs/a.md, docs/b.md). $_update',
      ));
      repairAll();
      expect(check().code, 0);
      expect(
        nodeIds(),
        containsAll([
          'docs_a_concept',
          'docs_b_concept',
          'lib_c',
          'lib_c_main',
        ]),
      );
    });

    test('puts back a doc a rebuild dropped, and keeps the other docs and '
        'the code', () {
      repairAll();
      dropB();
      expect(nodeIds(), contains('docs_b'), reason: 'the heading node');
      expect(nodeIds(), isNot(contains('docs_b_concept')));
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 1 doc (missing from the graph: '
            'docs/b.md). $_update',
      ));
      expect(check(['--repair']), (
        code: 0,
        output: 'graphify: repaired 1 doc from the cache (docs/b.md).',
      ));
      expect(check(), (
        code: 0,
        output: 'graphify: the graph is current (2 docs checked).',
      ));
      expect(
        nodeIds(),
        containsAll([
          'docs_a_concept',
          'docs_b_concept',
          'lib_c',
          'lib_c_main',
        ]),
      );
      expect(nodes().where((node) => node['community'] == null), isEmpty);
    });

    test('keeps a saved label of a community the repair left alone', () {
      repairAll();
      dropB();
      final code = nodes().firstWhere((node) => node['id'] == 'lib_c');
      final labels = File(
        p.join(repo.path, 'graphify-out', '.graphify_labels.json'),
      );
      final saved = jsonDecode(labels.readAsStringSync()) as Map;
      labels.writeAsStringSync(
        jsonEncode({...saved, '${code['community']}': 'Hand label'}),
      );
      expect(check(['--repair']).code, 0);
      final after = jsonDecode(labels.readAsStringSync()) as Map;
      final community = nodes().firstWhere(
        (node) => node['id'] == 'lib_c',
      )['community'];
      expect(after['$community'], 'Hand label');
    });

    test('leaves new, changed and deleted docs to /graphify . --update', () {
      writeFile(repo, 'docs/old.md', '# Old\n\ngone soon\n');
      extract('prompt one', ['docs/old.md']);
      expect(check(['--repair']).code, 0);
      dropB();
      File(p.join(repo.path, 'docs', 'old.md')).deleteSync();
      writeFile(repo, 'docs/a.md', '# A\n\nalpha, changed\n');
      writeFile(repo, 'docs/n.md', '# N\n\nnew\n');
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 4 docs (new or changed: '
            'docs/a.md, docs/n.md; missing from the graph: docs/b.md; '
            'deleted or no longer scanned: docs/old.md). $_update',
      ));
      // graphify's own rebuild, which the repair runs, drops the deleted doc.
      expect(check(['--repair']), (
        code: 1,
        output:
            'graphify: repaired 1 doc from the cache (docs/b.md).\n'
            'graphify: the graph is behind on 2 docs (new or changed: '
            'docs/a.md, docs/n.md). $_update',
      ));
    });

    test('says when there is nothing to repair', () {
      repairAll();
      expect(check(['--repair']), (
        code: 0,
        output: 'graphify: nothing to repair.',
      ));
    });

    test('waits for a rebuild that holds graphify\'s lock', () async {
      repairAll();
      dropB();
      final holder = await startPython(['-c', _holdLock, '6']);
      unawaited(holder.stderr.drain<void>());
      final said = holder.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();
      await said.firstWhere((line) => line == 'held');
      final repairing = await startPython([_script, '--repair']);
      final output = repairing.stdout.transform(utf8.decoder).join();
      unawaited(repairing.stderr.drain<void>());
      var finished = false;
      unawaited(repairing.exitCode.then((_) => finished = true));
      // It has had time to start and get to the lock, and it is still
      // waiting for it, not failed or done.
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(finished, isFalse, reason: 'it gave up or ignored the lock');
      await said.firstWhere((line) => line == 'released');
      expect(finished, isFalse, reason: 'it repaired while the lock was held');
      expect(await repairing.exitCode, 0);
      expect(
        (await output).trim(),
        'graphify: repaired 1 doc from the cache (docs/b.md).',
      );
      await holder.exitCode;
    });

    test('--after-rebuild waits for graphify\'s rebuild to end, then repairs, '
        'and writes only to the log, each line prefixed', () async {
      repairAll();
      dropB();
      // A rebuild in progress: something holds graphify's lock.
      final holder = await startPython(['-c', _holdLock, '5']);
      unawaited(holder.stderr.drain<void>());
      final said = holder.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();
      await said.firstWhere((line) => line == 'held');
      final job = await startPython(
        [_script, '--after-rebuild'],
        extra: {
          'GRAPHIFY_REBUILD_LOG': log.path,
          'APPSTEIN_REPAIR_START_WAIT': '5',
          'APPSTEIN_REPAIR_MAX_WAIT': '120',
        },
      );
      final output = job.stdout.transform(utf8.decoder).join();
      final errors = job.stderr.transform(utf8.decoder).join();
      var finished = false;
      unawaited(job.exitCode.then((_) => finished = true));
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(finished, isFalse, reason: 'it ran before the rebuild ended');
      await said.firstWhere((line) => line == 'released');
      expect(await job.exitCode, 0);
      await holder.exitCode;
      expect('${await output}${await errors}', isEmpty);
      final lines = log.readAsLinesSync();
      expect(
        lines,
        everyElement(matches(RegExp(r'^\[appstein\] \d{4}-\d\d-\d\d '))),
      );
      expect(
        lines.last,
        endsWith(' graphify: repaired 1 doc from the cache (docs/b.md).'),
      );
    });

    test('--after-rebuild rebuilds the code when graphify\'s hook did not', () {
      repairAll();
      writeFile(repo, 'lib/d.dart', 'void d() {}\n');
      final result = runPython(
        [_script, '--after-rebuild'],
        extra: {
          'GRAPHIFY_REBUILD_LOG': log.path,
          'APPSTEIN_REPAIR_START_WAIT': '0.5',
        },
      );
      expect(result.exitCode, 0, reason: logged());
      expect(logged().trim(), endsWith(' graphify: nothing to repair.'));
      expect(nodeIds(), contains('lib_d'));
    });

    test('--detach returns at once, prints nothing, and repairs in the '
        'background, appending to graphify\'s log', () async {
      repairAll();
      dropB();
      final started = runPython(
        [_script, '--detach'],
        extra: {
          'GRAPHIFY_REBUILD_LOG': log.path,
          'APPSTEIN_REPAIR_START_WAIT': '3',
        },
      );
      expect(started.exitCode, 0);
      expect('${started.stdout}${started.stderr}', isEmpty);
      // runPython returns once the pipes close, so the job must not hold
      // them, as it would hold git's.
      expect(logged(), isNot(contains('graphify: repaired')));
      // graphify's rebuild writes to the same log meanwhile; the job must
      // add to it, not write over it.
      log.writeAsStringSync(
        '[graphify] rebuilt meanwhile\n',
        mode: FileMode.append,
      );
      const repaired = 'graphify: repaired 1 doc from the cache (docs/b.md).';
      for (var i = 0; i < 120 && !logged().contains(repaired); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      expect(logged(), startsWith('[graphify] rebuilt meanwhile\n'));
      expect(logged(), contains(repaired));
      expect(check().code, 0);
    });

    test('--after-rebuild gives up, and says so in the log, when it takes too '
        'long', () async {
      repairAll();
      dropB();
      final holder = await startPython(['-c', _holdLock, '30']);
      unawaited(holder.stderr.drain<void>());
      final said = holder.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();
      await said.firstWhere((line) => line == 'held');
      final job = await startPython(
        [_script, '--after-rebuild'],
        extra: {
          'GRAPHIFY_REBUILD_LOG': log.path,
          'APPSTEIN_REPAIR_START_WAIT': '0',
          'APPSTEIN_REPAIR_MAX_WAIT': '0',
          // The limit is this plus a minute: one second.
          'GRAPHIFY_REBUILD_TIMEOUT': '-59',
        },
      );
      unawaited(job.stdout.drain<void>());
      unawaited(job.stderr.drain<void>());
      // With the lock held, the repair waits for it; the limit ends that.
      expect(await job.exitCode.timeout(const Duration(seconds: 25)), 3);
      expect(
        logged().trim(),
        endsWith(' graphify: could not repair the graph: it took too long.'),
      );
      holder.kill();
      await holder.exitCode;
    });

    test(
      '--after-rebuild does not wait for a lock file nobody holds',
      () async {
        repairAll();
        dropB();
        // What a killed rebuild leaves behind.
        writeFile(repo, 'graphify-out/.rebuild.lock', '12345\n');
        final job = await startPython(
          [_script, '--after-rebuild'],
          extra: {
            'GRAPHIFY_REBUILD_LOG': log.path,
            'APPSTEIN_REPAIR_START_WAIT': '0.5',
            'APPSTEIN_REPAIR_MAX_WAIT': '300',
          },
        );
        unawaited(job.stdout.drain<void>());
        unawaited(job.stderr.drain<void>());
        expect(await job.exitCode.timeout(const Duration(seconds: 60)), 0);
        expect(
          logged().trim(),
          endsWith(' graphify: repaired 1 doc from the cache (docs/b.md).'),
        );
      },
    );

    test('--after-rebuild does nothing while a merge or rebase is in '
        'progress', () {
      repairAll();
      dropB();
      writeFile(repo, '.git/MERGE_HEAD', 'deadbeef\n');
      final result = runPython(
        [_script, '--after-rebuild'],
        extra: {
          'GRAPHIFY_REBUILD_LOG': log.path,
          'APPSTEIN_REPAIR_START_WAIT': '0.5',
        },
      );
      expect(result.exitCode, 0, reason: logged());
      final lines = log.readAsLinesSync();
      expect(lines, hasLength(1));
      expect(
        lines.single,
        endsWith(
          ' graphify: a merge or rebase is in progress; the job that follows '
          'it will repair the graph.',
        ),
      );
      expect(check().code, 1, reason: 'nothing was repaired');
    });

    test('puts back the newest extraction that adds something, not a newer '
        'one with only the doc node', () {
      repairAll();
      dropB();
      extract('another agent prompt', ['docs/b.md'], flags: ['--only-heading']);
      expect(check().code, 1);
      expect(check(['--repair']), (
        code: 0,
        output: 'graphify: repaired 1 doc from the cache (docs/b.md).',
      ));
      expect(nodeIds(), contains('docs_b_concept'));
    });

    /// Rewrites every cache entry that holds docs/b.md's concept node.
    void editBEntries(String Function(String) edit) {
      final cache = Directory(p.join(repo.path, 'graphify-out', 'cache'));
      var edited = 0;
      for (final file in cache.listSync(recursive: true).whereType<File>()) {
        final text = file.readAsStringSync();
        if (text.contains('docs_b_concept')) {
          file.writeAsStringSync(edit(text));
          edited++;
        }
      }
      expect(edited, greaterThan(0));
    }

    test('reads cache entries as graphify does: turns the root placeholder '
        'in ids back', () {
      repairAll();
      dropB();
      editBEntries(
        (text) => text.replaceAll(
          'docs_b_concept',
          r'$graphify-root$_docs_b_concept',
        ),
      );
      expect(check(['--repair']).code, 0);
      final ids = nodeIds();
      expect(ids.where((id) => id.contains('graphify-root')), isEmpty);
      expect(ids.where((id) => id.endsWith('_docs_b_concept')), isNotEmpty);
      expect(check().code, 0);
    });

    test('skips a cache entry whose nodes come from another file', () {
      repairAll();
      editBEntries((text) => text.replaceAll('"docs/b.md"', '"docs/a.md"'));
      expect(check(), (
        code: 1,
        output:
            'graphify: the graph is behind on 1 doc (new or changed: '
            'docs/b.md). $_update',
      ));
    });

    test("says when graphify's rebuild fails, quoting its last line", () {
      repairAll();
      dropB();
      writeFile(
        repo,
        'shim/sitecustomize.py',
        'import graphify.watch\n'
            'def fail(*a, **k):\n'
            "    print('the rebuild blew up')\n"
            '    return False\n'
            'graphify.watch._rebuild_code = fail\n',
      );
      expect(check(['--repair'], {'PYTHONPATH': p.join(repo.path, 'shim')}), (
        code: 3,
        output:
            "graphify: could not repair the graph: graphify's rebuild "
            'failed. It said: the rebuild blew up',
      ));
    });

    test("cannot repair when graphify's rebuild no longer takes the "
        'extraction', () {
      repairAll();
      dropB();
      // As a graphify release that rebuilt without the function the repair
      // hooks into would.
      writeFile(
        repo,
        'shim/sitecustomize.py',
        'import graphify.watch\n'
            'graphify.watch._rebuild_code = lambda *a, **k: True\n',
      );
      expect(check(['--repair'], {'PYTHONPATH': p.join(repo.path, 'shim')}), (
        code: 3,
        output:
            "graphify: could not repair the graph: graphify's rebuild didn't "
            'put back docs/b.md.',
      ));
    });
  });
}
