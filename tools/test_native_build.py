#!/usr/bin/env python3
"""Negative checks for pinned-source and artifact-cache validation (no downloads)."""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import build_native as native


class NativeBuildChecks(unittest.TestCase):
    def test_changed_archive_invalidates_reuse(self):
        with tempfile.TemporaryDirectory() as work, patch.object(native, 'OUT', Path(work)):
            archive = Path(work) / 'libtest.a'
            manifest = Path(work) / 'manifest.json'
            archive.write_bytes(b'original')
            native.record(manifest, {'compiler': 'test'}, [archive.name])
            self.assertTrue(native.cached(manifest, {'compiler': 'test'}, [archive.name]))
            archive.write_bytes(b'changed')
            self.assertFalse(native.cached(manifest, {'compiler': 'test'}, [archive.name]))
            self.assertFalse(native.cached(manifest, {'compiler': 'another'}, [archive.name]))

    def test_supplied_sqlite_source_must_match_pin(self):
        with tempfile.TemporaryDirectory() as work, patch.object(native, 'OUT', Path(work)):
            (Path(work) / 'sqlite3.c').write_bytes(b'untrusted source')
            with self.assertRaisesRegex(SystemExit, 'Pinned source hash mismatch'):
                native.sources('sqlite', Path(work), offline=True)

    def test_offline_missing_source_never_downloads(self):
        with tempfile.TemporaryDirectory() as work, patch.object(native, 'CACHE', Path(work)):
            with patch.object(native.urllib.request, 'urlopen') as request:
                with self.assertRaisesRegex(SystemExit, 'Offline source missing'):
                    native.download(native.PINS['openssl'], offline=True)
                request.assert_not_called()

    def test_corrupt_cached_openssl_is_rejected(self):
        with tempfile.TemporaryDirectory() as work, patch.object(native, 'CACHE', Path(work)):
            name = native.PINS['openssl']['url'].rsplit('/', 1)[1]
            (Path(work) / name).write_bytes(b'corrupt tarball')
            with self.assertRaisesRegex(SystemExit, 'Pinned archive hash mismatch'):
                native.download(native.PINS['openssl'], offline=True)


if __name__ == '__main__': unittest.main()
