"""Test fixture: caches a fake semantic extraction of some docs, the way
`/graphify . --update` would, using graphify's own cache writer.

Run it with graphify's Python, from the fixture repo's root:

    graphify_fixture.py <prompt text> [--partial] [--deep] <doc>...

Each doc gets one node. The prompt text picks the p<fingerprint> cache
folder, as each agent's extraction prompt does. --partial marks the entries
as cut short; --deep writes them in deep mode's cache.
"""

import sys
from pathlib import Path

from graphify.cache import save_semantic_cache


def main(argv):
    prompt, *rest = argv
    docs = [a for a in rest if not a.startswith('--')]
    root = Path.cwd()
    paths = [str(root / d) for d in docs]
    nodes = [{'id': f'doc_{i}', 'label': doc, 'file_type': 'document',
              'source_file': doc} for i, doc in enumerate(docs)]
    save_semantic_cache(
        nodes, [], [], root=root, allowed_source_files=paths,
        mode='deep' if '--deep' in rest else None, prompt=prompt,
        partial_source_files=paths if '--partial' in rest else None)


if __name__ == '__main__':
    main(sys.argv[1:])
