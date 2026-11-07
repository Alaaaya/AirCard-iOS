"""Explicit version-targeted release notes. Missing notes are deliberately empty."""
import json
import pathlib
import sys


def metadata(path, target):
    if not path.exists():
        return {'releaseNotes': {}}
    entries = json.loads(path.read_text())
    notes = entries.get(target, {})
    if not isinstance(notes, dict) or any(k not in ('ar', 'en') or not isinstance(v, str) for k, v in notes.items()):
        raise ValueError('Expected curated ar/en release notes for exact target')
    return {'releaseNotes': notes}


if __name__ == '__main__':
    print(json.dumps(metadata(pathlib.Path(sys.argv[1]), sys.argv[2]), ensure_ascii=False))
