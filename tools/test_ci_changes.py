#!/usr/bin/env python3
"""Keep documentation PRs cheap without skipping checks for unknown source paths."""
import unittest
from ci_changes import classify


class ChangesTests(unittest.TestCase):
    def test_docs_only(self):
        self.assertFalse(any(classify(['README.md', 'docs/book.typ', '']).values()))

    def test_python_without_native(self):
        selected = classify(['languages/python/src/sqlodin/client.py'])
        self.assertTrue(selected['python'])
        self.assertFalse(selected['native'])

    def test_formal_without_native(self):
        selected = classify(['specs/QuorumReadReconnect.tla', 'specs/QuorumReadReconnect.cfg'])
        self.assertTrue(selected['formal'])
        self.assertFalse(selected['native'])

    def test_unknown_source_gets_tests(self):
        selected = classify(['new-package/main.odin'])
        self.assertTrue(selected['native'] and selected['python'])

    def test_dependency_change(self):
        selected = classify(['deps/paxos-odin'])
        self.assertTrue(selected['native'] and selected['upstream'])


if __name__ == '__main__':
    unittest.main()
