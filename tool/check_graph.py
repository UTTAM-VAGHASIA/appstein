"""Says whether the graphify knowledge graph holds the current docs (spec §19.6).

graphify's git hooks rebuild only the code structure. What the docs mean is
extracted by an LLM during `/graphify . --update`, so a doc edited after that
run stays behind in the graph until the next one. This check finds those docs:

- new or changed: no extraction of the doc's current content is cached;
- missing from the graph: an extraction is cached, but graph.json has no node
  from the doc;
- deleted or no longer scanned: graph.json has nodes from a doc that graphify
  no longer scans.

An extraction made with any agent's extraction prompt counts, because each
agent's graphify skill ships its own prompt (docs/guide/docs-tooling.md).

Run it with graphify's Python, from the repo root:

    "$(cat graphify-out/.graphify_python)" tool/check_graph.py [--quiet]

Exit codes: 0 the graph is current, 1 docs are behind, 3 the check couldn't
run. With --quiet, nothing is printed when the graph is current.
"""

import json
import sys
from pathlib import Path

_DOC_KINDS = ('document', 'paper', 'image')
_MAX_NAMES = 5


def _entry_is_valid(entry: Path) -> bool:
    """graphify's own rule: a partial or empty cache entry is a miss."""
    try:
        data = json.loads(entry.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return False
    return (isinstance(data, dict) and not data.get('partial')
            and bool(data.get('nodes') or data.get('hyperedges')))


def _is_extracted(doc: Path, root: Path, cache: Path, file_hash) -> bool:
    """Whether some prompt's cache, in any mode, holds this exact content."""
    try:
        name = file_hash(doc, root) + '.json'
    except OSError:
        return False
    for kind in sorted(cache.glob('semantic*')):
        if not kind.is_dir():
            continue
        folders = [kind] + sorted(d for d in kind.iterdir() if d.is_dir())
        if any(_entry_is_valid(f / name) for f in folders if (f / name).is_file()):
            return True
    return False


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


def find_behind(root: Path) -> dict:
    """The number of docs, and the docs the graph is behind on, by reason.

    Raises on anything that stops the check, such as a missing graph or a
    graphify that lacks the functions used here.
    """
    from graphify.cache import file_hash
    from graphify.detect import CODE_EXTENSIONS, FileType, classify_file, detect
    from graphify.paths import GRAPHIFY_OUT

    out = Path(GRAPHIFY_OUT)
    out = out if out.is_absolute() else root / out
    graph_file = out / 'graph.json'
    if not graph_file.is_file():
        raise FileNotFoundError(
            f'there is no graph yet ({graph_file} is missing); run /graphify .')
    graph = json.loads(graph_file.read_text(encoding='utf-8'))

    detected = detect(root)
    docs = sorted({
        Path(f).resolve().relative_to(root).as_posix()
        for kind in _DOC_KINDS for f in detected['files'].get(kind, [])
    })
    in_graph = {
        _relative(str(node['source_file']), root)
        for node in graph.get('nodes', []) if node.get('source_file')
    }
    changed, missing = [], []
    for doc in docs:
        if not _is_extracted(root / doc, root, out / 'cache', file_hash):
            changed.append(doc)
        elif doc not in in_graph:
            missing.append(doc)
    doc_set = set(docs)
    removed = sorted(
        source for source in in_graph
        if source not in doc_set and source != 'None'
        and Path(source).suffix.lower() not in CODE_EXTENSIONS
        and classify_file(Path(source)) not in (FileType.CODE, None)
    )
    return {'docs': len(docs), 'new or changed': changed,
            'missing from the graph': missing,
            'deleted or no longer scanned': removed}


def main(argv: list) -> int:
    # On Windows, Python prints in the console's code page. Paths may hold any
    # character, and git's sh and the tests read UTF-8.
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8', errors='replace')
    quiet = '--quiet' in argv
    unknown = [a for a in argv if a != '--quiet']
    if unknown:
        print(f'usage: check_graph.py [--quiet] (unknown: {" ".join(unknown)})',
              file=sys.stderr)
        return 3
    try:
        result = find_behind(Path.cwd().resolve())
    except Exception as error:  # noqa: BLE001 - any failure means "couldn't check"
        print(f'graphify: the graph check could not run: {error}')
        return 3
    reasons = [(k, v) for k, v in result.items() if k != 'docs' and v]
    if not reasons:
        if not quiet:
            print(f'graphify: the graph is current ({result["docs"]} docs checked).')
        return 0
    count = sum(len(v) for _, v in reasons)
    detail = '; '.join(f'{k}: {_names(v)}' for k, v in reasons)
    noun = 'doc' if count == 1 else 'docs'
    print(f'graphify: the graph is behind on {count} {noun} ({detail}). '
          'Run /graphify . --update before relying on it.')
    return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
