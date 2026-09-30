"""Says whether the graphify knowledge graph holds the current docs, and puts
back docs whose extraction is cached but missing from it (spec §19.6).

graphify's git hooks rebuild only the code structure. What the docs mean is
extracted by an LLM during `/graphify . --update`, so a doc edited after that
run stays behind in the graph until the next one. This check finds those docs:

- new or changed: no extraction of the doc's current content is cached;
- missing from the graph: an extraction is cached, but graph.json has none of
  the nodes it adds (graphify's own heading nodes for the doc don't count);
- deleted or no longer scanned: graph.json has nodes from a doc that graphify
  no longer scans.

An extraction made with any agent's extraction prompt counts, because each
agent's graphify skill ships its own prompt (docs/guide/docs-tooling.md).

A doc goes missing from the graph when graphify rebuilds the code while the
doc isn't on disk, for example on a branch that lacks it: the rebuild drops
the doc's nodes, and no code rebuild can extract them again. --repair puts
them back from the cache, with no LLM, and lets graphify finish the graph the
way its own rebuild does: communities, labels, report and graph.html.

Run it with graphify's Python, from the repo root:

    "$(cat graphify-out/.graphify_python)" tool/check_graph.py [--quiet]
    "$(cat graphify-out/.graphify_python)" tool/check_graph.py --repair

  (no mode)        Check. --quiet prints nothing when the graph is current.
                   --skip-repairable (the hooks use it, right after starting
                   a background repair) reports docs missing from the graph
                   as being repaired, instead of asking for an update.
  --repair         Repair now, then report what is still behind.
  --detach         Start --after-rebuild in a background process and return.
  --after-rebuild  Wait for graphify's rebuild to finish, then rebuild once
                   more with the missing docs put back. It writes only to
                   graphify's rebuild log.

Exit codes: 0 the graph is current (apart from docs being repaired), 1 docs
are behind, 3 the check or the repair couldn't run, or bad usage.
"""

import contextlib
import io
import json
import multiprocessing
import os
import subprocess
import sys
import threading
import time
from pathlib import Path

_DOC_KINDS = ('document', 'paper', 'image')
_REASONS = ('new or changed', 'missing from the graph',
            'deleted or no longer scanned')
_MISSING = 'missing from the graph'
_MAX_NAMES = 5
_MODES = ('--repair', '--detach', '--after-rebuild')
_USAGE = ('usage: check_graph.py [--quiet] [--skip-repairable] | --repair | '
          '--detach | --after-rebuild')


def _valid_extraction(entry: Path):
    """The extraction in a cache entry, or None when graphify would treat the
    entry as a miss: unreadable, partial, or with no nodes and no hyperedges."""
    try:
        data = json.loads(entry.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return None
    if (isinstance(data, dict) and not data.get('partial')
            and (data.get('nodes') or data.get('hyperedges'))):
        return data
    return None


def _extractions(doc: Path, root: Path, cache: Path, helpers: tuple) -> list:
    """Every valid cached extraction of this exact content, from any prompt's
    cache and in any mode, newest first. Entries are read as graphify's
    load_cached reads them: one whose nodes come from another file is a miss,
    and the root placeholder in its ids is turned back into the real ones."""
    file_hash, matches_path, absolutize_ids = helpers
    try:
        name = file_hash(doc, root) + '.json'
    except OSError:
        return []
    entries = []
    for kind in sorted(cache.glob('semantic*')):
        if not kind.is_dir():
            continue
        for folder in [kind] + sorted(d for d in kind.iterdir() if d.is_dir()):
            if (folder / name).is_file():
                entries.append(folder / name)
    found = []
    for entry in sorted(entries, key=lambda e: e.stat().st_mtime, reverse=True):
        data = _valid_extraction(entry)
        if data is None or not matches_path(data, doc, root):
            continue
        absolutize_ids(data, doc, root)
        found.append(data)
    return found


def _is_ast(item: dict) -> bool:
    """Whether graphify's code rebuild made a node or edge, by graphify's own
    rule (graphify.build._is_ast_tier): its _origin marker, or for items from
    before the marker, a source_location such as 'L12'. It is copied, not
    imported, because importing graphify.build costs 0.2 s on every commit;
    the repair tests, which run graphify's real rebuild, catch a change."""
    origin = item.get('_origin')
    if origin is not None:
        return origin == 'ast'
    location = item.get('source_location')
    return (isinstance(location, str) and location[:1] == 'L'
            and location[1:2].isdigit())


def _ids(data: dict) -> set:
    """The ids of the nodes and hyperedges in a graph or an extraction."""
    return {
        item.get('id')
        for bucket in ('nodes', 'hyperedges')
        for item in data.get(bucket, [])
        if isinstance(item, dict) and isinstance(item.get('id'), str)
    }


def _relative(path: str, root: Path) -> str:
    """A graph.json source_file as a forward-slash path relative to root."""
    text = path.replace('\\', '/')
    candidate = Path(text)
    if candidate.is_absolute():
        try:
            return candidate.resolve().relative_to(root).as_posix()
        except ValueError:
            return candidate.as_posix()
    return text


def _names(paths: list) -> str:
    shown = ', '.join(paths[:_MAX_NAMES])
    more = len(paths) - _MAX_NAMES
    return f'{shown} and {more} more' if more > 0 else shown


def _docs(count: int) -> str:
    return f'{count} {"doc" if count == 1 else "docs"}'


def _out_dir(root: Path) -> Path:
    from graphify.paths import GRAPHIFY_OUT
    out = Path(GRAPHIFY_OUT)
    return out if out.is_absolute() else root / out


def _require_graph(out: Path) -> Path:
    """graph.json in [out], or FileNotFoundError when there is none."""
    graph_file = out / 'graph.json'
    if not graph_file.is_file():
        raise FileNotFoundError(
            f'there is no graph yet ({graph_file} is missing); run /graphify .')
    return graph_file


def find_behind(root: Path) -> dict:
    """The number of docs, the docs the graph is behind on by reason, and
    under 'cached' the cached extractions of each doc missing from the graph.

    Raises on anything that stops the check, such as a missing graph or a
    graphify that lacks the functions used here.
    """
    from graphify.cache import (
        _absolutize_ids_in, _semantic_entry_matches_path, file_hash)
    from graphify.detect import CODE_EXTENSIONS, FileType, classify_file, detect

    helpers = (file_hash, _semantic_entry_matches_path, _absolutize_ids_in)
    out = _out_dir(root)
    graph_file = _require_graph(out)
    graph = json.loads(graph_file.read_text(encoding='utf-8'))
    graph_ids = _ids(graph)

    detected = detect(root)
    docs = sorted({
        _relative(str(f), root)
        for kind in _DOC_KINDS for f in detected['files'].get(kind, [])
    })
    in_graph = {
        _relative(str(node['source_file']), root)
        for node in graph.get('nodes', []) if node.get('source_file')
    }
    # graphify's code rebuild adds heading nodes of its own for a Markdown
    # doc, and one can have the same id as the extraction's node for the doc
    # itself (the heading node wins). Only the nodes an extraction adds count.
    heading_ids = {n.get('id') for n in graph.get('nodes', []) if _is_ast(n)}
    changed, missing, cached = [], [], {}
    for doc in docs:
        extractions = _extractions(root / doc, root, out / 'cache', helpers)
        if not extractions:
            changed.append(doc)
            continue
        # Only an extraction that adds something counts: a newer one with
        # just the doc's own node (from another agent's prompt) must not hide
        # an older one the repair could put back.
        useful = [(e, a) for e in extractions
                  if (a := _ids(e) - heading_ids)]
        if useful and not any(a & graph_ids for _, a in useful):
            missing.append(doc)
            cached[doc] = [e for e, _ in useful]
    doc_set = set(docs)
    removed = sorted(
        source for source in in_graph
        if source not in doc_set and source != 'None'
        and Path(source).suffix.lower() not in CODE_EXTENSIONS
        and classify_file(Path(source)) not in (FileType.CODE, None)
    )
    return {'docs': len(docs), 'new or changed': changed,
            _MISSING: missing, 'deleted or no longer scanned': removed,
            'cached': cached}


def _rebuild_root(root: Path, out: Path) -> Path:
    """The folder graphify's hook rebuilds: the one [out]/.graphify_root
    names, when it is a folder inside [root], else '.'."""
    try:
        text = (out / '.graphify_root').read_text(
            encoding='utf-8-sig').strip()
        if text:
            candidate = Path(text)
            resolved = candidate.resolve()
            here = root.resolve()
            if (resolved == here or here in resolved.parents) \
                    and resolved.is_dir():
                return candidate
    except (OSError, RuntimeError):
        pass
    return Path('.')


def repair(root: Path, echo=None, rebuild: bool = False) -> tuple:
    """Puts the docs missing from the graph back from graphify's cache, and
    returns (the docs repaired, find_behind's result afterwards).

    It holds graphify's rebuild lock, waiting for a running rebuild first,
    and runs graphify's own full code rebuild with the cached extractions
    added to what it keeps from the existing graph, so graphify clusters,
    names communities and writes the report as usual. No LLM runs. With
    [rebuild], the code rebuild runs even when no doc is missing. [echo]
    receives what graphify printed. Raises when the repair can't run or
    graphify's rebuild doesn't put the docs back.
    """
    import graphify.watch as watch

    out = _out_dir(root)
    # Before the lock, which creates the folder.
    _require_graph(out)
    with watch._rebuild_lock(out, blocking=True):
        before = find_behind(root)
        docs = before[_MISSING]
        if not docs and not rebuild:
            return [], before
        added = {'nodes': [], 'edges': [], 'hyperedges': []}
        seen = {bucket: set() for bucket in added}
        for doc in docs:
            newest = before['cached'][doc][0]
            for bucket, items in added.items():
                for item in newest.get(bucket, []):
                    if not isinstance(item, dict):
                        continue
                    # Two docs may cache the same entity or link: add it once.
                    key = item.get('id')
                    if key is None:
                        key = json.dumps(item, sort_keys=True, default=str)
                    if key not in seen[bucket]:
                        seen[bucket].add(key)
                        items.append(item)
        # Stamped as graphify stamps what it keeps from an existing graph.
        for item in added['nodes'] + added['edges']:
            item.setdefault('_origin', 'ast' if _is_ast(item) else 'semantic')

        keep = watch._reconcile_existing_graph

        def keep_and_add(*args, **kwargs):
            result, existing = keep(*args, **kwargs)
            have = {n.get('id') for n in result['nodes']}
            result['nodes'] = result['nodes'] + [
                n for n in added['nodes'] if n.get('id') not in have]
            result['edges'] = result['edges'] + added['edges']
            result['hyperedges'] = (
                result.get('hyperedges', []) + added['hyperedges'])
            return result, existing

        printed = io.StringIO()
        watch._reconcile_existing_graph = keep_and_add
        try:
            with contextlib.redirect_stdout(printed), \
                    contextlib.redirect_stderr(printed):
                # As in graphify's own full rebuild: it covers any change a
                # hook queued while the lock was held.
                watch._drain_pending(out)
                rebuilt = watch._rebuild_code(
                    _rebuild_root(root, out), acquire_lock=False)
        finally:
            watch._reconcile_existing_graph = keep
        if echo is not None:
            echo(printed.getvalue())
        after = find_behind(root)
    lines = [line.strip() for line in printed.getvalue().splitlines()
             if line.strip()]
    said = f' It said: {lines[-1]}' if lines else ''
    if not rebuilt:
        raise RuntimeError(f"graphify's rebuild failed.{said}")
    still = [d for d in docs if d in after[_MISSING]]
    if still:
        raise RuntimeError(
            f"graphify's rebuild didn't put back {_names(still)}.{said}")
    return docs, after


def _behind_line(result: dict, reasons=_REASONS):
    """The one-line warning for [reasons], or None when none has docs."""
    found = [(k, result[k]) for k in reasons if result[k]]
    if not found:
        return None
    count = sum(len(v) for _, v in found)
    detail = '; '.join(f'{k}: {_names(v)}' for k, v in found)
    return (f'graphify: the graph is behind on {_docs(count)} ({detail}). '
            'Run /graphify . --update before relying on it.')


def _check(root: Path, quiet: bool, skip_repairable: bool) -> int:
    try:
        result = find_behind(root)
    except Exception as error:  # noqa: BLE001 - any failure means "couldn't check"
        print(f'graphify: the graph check could not run: {error}')
        return 3
    reasons = _REASONS
    if skip_repairable and result[_MISSING]:
        docs = result[_MISSING]
        print(f'graphify: repairing {_docs(len(docs))} from the cache in the '
              f'background ({_names(docs)}).')
        reasons = tuple(r for r in _REASONS if r != _MISSING)
    line = _behind_line(result, reasons)
    if line is None:
        if not quiet and not (skip_repairable and result[_MISSING]):
            print(f'graphify: the graph is current ({_docs(result["docs"])} '
                  'checked).')
        return 0
    print(line)
    return 1


def _repair(root: Path, say, echo=None, rebuild: bool = False) -> int:
    try:
        docs, after = repair(root, echo, rebuild)
    except Exception as error:  # noqa: BLE001 - any failure means "couldn't repair"
        say(f'graphify: could not repair the graph: {error}')
        return 3
    if docs:
        say(f'graphify: repaired {_docs(len(docs))} from the cache '
            f'({_names(docs)}).')
    else:
        say('graphify: nothing to repair.')
    line = _behind_line(after)
    if line is None:
        return 0
    say(line)
    return 1


def _log_path() -> Path:
    """graphify's rebuild log, where its hooks send background output:
    GRAPHIFY_REBUILD_LOG, or .cache/graphify-rebuild.log in $HOME, which
    graphify's hooks use (on Windows, git's sh sets HOME)."""
    configured = os.environ.get('GRAPHIFY_REBUILD_LOG')
    if configured:
        return Path(configured)
    home = os.environ.get('HOME') or os.path.expanduser('~')
    return Path(home) / '.cache' / 'graphify-rebuild.log'


def _rebuild_env() -> dict:
    """The environment graphify's hooks give a rebuild: a fixed hash seed, so
    clustering is reproducible, and one worker on Windows."""
    env = dict(os.environ, PYTHONHASHSEED='0')
    if os.name == 'nt':
        env.setdefault('GRAPHIFY_MAX_WORKERS', '1')
    return env


def _detach(root: Path) -> int:
    """Starts --after-rebuild in a process of its own, as graphify's hooks
    start their rebuild, and returns at once.

    The process gets none of the hook's handles, so git doesn't wait for
    it. It opens the log itself: a handle passed down would write at the
    offset it had when opened, over what graphify wrote since.
    """
    try:
        options = dict(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       stdin=subprocess.DEVNULL, cwd=str(root),
                       close_fds=True, env=_rebuild_env())
        command = [sys.executable, str(Path(__file__).resolve()),
                   '--after-rebuild']
        if os.name == 'nt':
            flags = 0x08000000 | 0x00000200  # NO_WINDOW | NEW_PROCESS_GROUP
            try:
                # Also leave the hook's job object, if the system allows.
                subprocess.Popen(command, creationflags=flags | 0x01000000,
                                 **options)
            except OSError:
                subprocess.Popen(command, creationflags=flags, **options)
        else:
            subprocess.Popen(command, start_new_session=True, **options)
    except Exception as error:  # noqa: BLE001 - any failure means "couldn't start"
        print(f'graphify: the background graph repair could not start: {error}')
        return 3
    return 0


def _seconds(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return default


def _job_limit():
    """The seconds the background job may take, or None for no limit.

    APPSTEIN_REPAIR_TIMEOUT sets it directly. Otherwise
    GRAPHIFY_REBUILD_TIMEOUT is read as graphify's hooks read it: an int,
    default 600 (600 also when it isn't one), and zero or less means no
    limit. A limit is that plus a minute for the wait for the lock and the
    repair's own steps.
    """
    direct = os.environ.get('APPSTEIN_REPAIR_TIMEOUT')
    if direct is not None:
        try:
            return float(direct)
        except ValueError:
            pass
    try:
        timeout = int(os.environ.get('GRAPHIFY_REBUILD_TIMEOUT', '600'))
    except ValueError:
        timeout = 600
    return None if timeout <= 0 else timeout + 60


def _lock_is_free(out: Path) -> bool:
    """Whether nobody holds graphify's rebuild lock. If graphify's lock can't
    be tried, say yes: the repair that follows reports the problem."""
    try:
        import graphify.watch as watch
        with watch._rebuild_lock(out, blocking=False) as acquired:
            return bool(acquired)
    except Exception:  # noqa: BLE001
        return True


def _in_progress(root: Path) -> bool:
    """Whether a merge, cherry-pick or rebase is under way in this repo."""
    try:
        found = subprocess.run(
            ['git', 'rev-parse', '--git-dir'], cwd=str(root),
            capture_output=True, text=True, encoding='utf-8')
        if found.returncode != 0:
            return False
        git_dir = root / found.stdout.strip()
    except (OSError, ValueError):
        return False
    return any((git_dir / name).exists() for name in (
        'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'rebase-merge', 'rebase-apply'))


def _after_rebuild(root: Path) -> int:
    """Waits for the rebuild graphify's hook just started, then repairs, and
    writes what happened to graphify's rebuild log.

    graphify's hook starts its rebuild in the background too, and Python can
    take seconds to start on Windows, so it first waits for graphify's lock
    file to appear, then for it to go. With no rebuild (graphify's hook
    skipped it) the file never appears, and it goes on after the first wait.
    It then runs graphify's code rebuild once more, with any missing docs
    put back: graphify's hook skips its rebuild during a merge or a rebase,
    and when another rebuild still holds the lock.

    It gives up after GRAPHIFY_REBUILD_TIMEOUT (graphify's own limit for a
    rebuild: whole seconds, default 600, read as graphify reads it) plus a
    minute for the whole job, the wait for the lock included: it logs that it
    took too long, kills any worker processes and exits, and the OS releases
    graphify's lock. A value of zero or less sets no limit, as graphify's
    hook does. APPSTEIN_REPAIR_TIMEOUT (seconds) sets the job's limit
    directly; the tests use it.

    While a merge or a rebase is in progress it waits for it to end (polling
    twice a second), up to APPSTEIN_REPAIR_MAX_WAIT seconds (default: the
    job's limit, or 600 without one), and logs a line if that runs out. The
    same bound applies to the wait for the lock.
    """
    try:
        log_file = _log_path()
        log_file.parent.mkdir(parents=True, exist_ok=True)
        log = open(log_file, 'a', encoding='utf-8', errors='replace')
    except OSError:
        return 3
    with log:
        writing = threading.Lock()

        def say(text: str) -> None:
            stamp = time.strftime('%Y-%m-%d %H:%M:%S')
            with writing:
                for line in text.splitlines():
                    if line.strip():
                        log.write(f'[appstein] {stamp} {line}\n')
                log.flush()

        def give_up() -> None:
            say('graphify: could not repair the graph: it took too long.')
            # As graphify's own watchdog: a rebuild's workers must not
            # outlive the job.
            for child in multiprocessing.active_children():
                child.kill()
            os._exit(3)

        seconds = _job_limit()
        limit = threading.Timer(seconds if seconds is not None else 0, give_up)
        limit.daemon = True
        if seconds is not None:
            limit.start()
        try:
            try:
                out = _out_dir(root)
                lock = out / '.rebuild.lock'
            except Exception as error:  # noqa: BLE001 - any failure means "couldn't repair"
                say(f'graphify: could not repair the graph: {error}')
                return 3
            until = time.monotonic() + _seconds('APPSTEIN_REPAIR_START_WAIT', 20)
            while not lock.exists() and time.monotonic() < until:
                time.sleep(0.1)
            longest = _seconds('APPSTEIN_REPAIR_MAX_WAIT',
                               seconds if seconds is not None else 600)
            until = time.monotonic() + longest
            while lock.exists() and time.monotonic() < until:
                # A lock file nobody holds (a killed rebuild left it) is no
                # reason to wait.
                if _lock_is_free(out):
                    break
                time.sleep(0.2)
            # The repair takes the lock itself, waiting for any rebuild that
            # starts meanwhile, so waiting for the operation to end is safe.
            until = time.monotonic() + longest
            while _in_progress(root):
                if time.monotonic() >= until:
                    say('graphify: a merge or rebase was still in progress '
                        'after waiting for it; the graph was not repaired.')
                    return 0
                time.sleep(0.5)
            return _repair(root, say, echo=say, rebuild=True)
        finally:
            limit.cancel()


def main(argv: list) -> int:
    # On Windows, Python prints in the console's code page. Paths may hold any
    # character, and git's sh, the log and the tests read UTF-8.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8', errors='replace')
    known = {'--quiet', '--skip-repairable', *_MODES}
    unknown = [a for a in argv if a not in known]
    modes = [a for a in argv if a in _MODES]
    if unknown or len(modes) > 1 or (modes and len(argv) > 1):
        extra = ' '.join(unknown) if unknown else ' '.join(argv)
        print(f'{_USAGE} (not understood: {extra})', file=sys.stderr)
        return 3
    root = Path.cwd().resolve()
    mode = modes[0] if modes else None
    if mode in ('--repair', '--after-rebuild') and \
            os.environ.get('PYTHONHASHSEED') != '0':
        # graphify's hooks cluster with a fixed hash seed; without it the
        # communities would shuffle. The seed is read at start-up, so run
        # again with it.
        return subprocess.run([sys.executable, str(Path(__file__).resolve()),
                               *argv], env=_rebuild_env()).returncode
    if mode == '--repair':
        return _repair(root, print)
    if mode == '--detach':
        return _detach(root)
    if mode == '--after-rebuild':
        return _after_rebuild(root)
    return _check(root, '--quiet' in argv, '--skip-repairable' in argv)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
