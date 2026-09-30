"""Test fixture: fakes what graphify does, with graphify's own code.

Run it with graphify's Python, from the fixture repo's root:

    graphify_fixture.py <prompt text> [--partial] [--deep] [--only-heading] <doc>...
    graphify_fixture.py --build

The first form caches a fake semantic extraction of the docs, the way
`/graphify . --update` would, with graphify's cache writer. Each doc gets a
node for the doc itself, whose id is the one graphify's code rebuild gives the
doc's own heading node (as in real extractions), and a concept node,
`<id>_concept`, unless --only-heading. The prompt text picks the
p<fingerprint> cache folder, as each agent's extraction prompt does.
--partial marks the entries as cut short; --deep writes them in deep mode's
cache.

--build runs graphify's code rebuild, as its git hooks do. It keeps what
graph.json holds from docs that are still on disk, and drops the rest.
"""

import re
import sys
from pathlib import Path


def doc_id(doc: str) -> str:
    """The id graphify gives a doc's own heading node: the path without its
    extension, lowercased, with every run of other characters as one '_'."""
    stem = doc.rsplit('.', 1)[0]
    return re.sub(r'[^0-9a-z]+', '_', stem.lower()).strip('_')


def extract(argv):
    from graphify.cache import save_semantic_cache

    prompt, *rest = argv
    docs = [a for a in rest if not a.startswith('--')]
    root = Path.cwd()
    paths = [str(root / d) for d in docs]
    nodes, edges = [], []
    for doc in docs:
        nodes.append({'id': doc_id(doc), 'label': doc, 'file_type': 'document',
                      'source_file': doc})
        if '--only-heading' in rest:
            continue
        concept = doc_id(doc) + '_concept'
        nodes.append({'id': concept, 'label': f'Concept of {doc}',
                      'file_type': 'concept', 'source_file': doc})
        edges.append({'source': doc_id(doc), 'target': concept,
                      'relation': 'mentions', 'confidence': 'EXTRACTED',
                      'source_file': doc, 'weight': 1.0})
    save_semantic_cache(
        nodes, edges, [], root=root, allowed_source_files=paths,
        mode='deep' if '--deep' in rest else None, prompt=prompt,
        partial_source_files=paths if '--partial' in rest else None)


def build():
    from graphify.watch import _rebuild_code

    if not _rebuild_code(Path('.'), block_on_lock=True):
        sys.exit('graphify_fixture.py: the rebuild failed')


if __name__ == '__main__':
    if sys.argv[1:] == ['--build']:
        build()
    else:
        extract(sys.argv[1:])
