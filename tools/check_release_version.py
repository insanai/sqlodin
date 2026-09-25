#!/usr/bin/env python3
"""Require a release tag and matching native and Python package versions."""
import os
from pathlib import Path
import re
import tomllib

ROOT = Path(__file__).resolve().parents[1]
VERSIONS = {
    'CLI': re.search(r'VERSION :: "([^"]+)"', (ROOT / 'cli/main.odin').read_text())[1],
    'library': re.search(r'VERSION :: "([^"]+)"', (ROOT / 'src/sqlodin.odin').read_text())[1],
    'package': re.search(r'^version = "([^"]+)"',
                         (ROOT / 'languages/python/pyproject.toml').read_text(), re.M)[1],
    'Python': re.search(r"__version__ = '([^']+)'",
                        (ROOT / 'languages/python/src/sqlodin/__init__.py').read_text())[1],
}
lock = tomllib.loads((ROOT / 'languages/python/uv.lock').read_text())
VERSIONS['lockfile'] = next(p['version'] for p in lock['package'] if p['name'] == 'sqlodin')
if len(set(VERSIONS.values())) != 1:
    raise SystemExit(f'Release versions differ: {VERSIONS}')
version = VERSIONS['CLI']
if os.environ.get('GITHUB_REF_TYPE') != 'tag' or os.environ.get('GITHUB_REF_NAME') != f'v{version}':
    raise SystemExit(f'Run this workflow on the v{version} tag')
print(f'Release version verified: {version}')
