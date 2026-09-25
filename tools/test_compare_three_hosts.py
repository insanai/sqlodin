"""Exercise the remote worker without SSH, including failed threaded requests."""
import contextlib
import io
import json
from pathlib import Path
import re
import sys
import tempfile
import threading
import types
import unittest
from unittest.mock import patch

from compare_three_hosts import WORKER


class WorkerTest(unittest.TestCase):
    def run_worker(self, failure=None):
        balances = [0] * 1024
        lock = threading.Lock()

        class Result(list):
            def scalar(self):
                return self[0][0]

        class Connection:
            def __enter__(self): return self
            def __exit__(self, *args): self.close()
            def close(self): pass
            def session_epoch(self): pass
            def execute(self, text):
                if text.startswith('UPDATE'):
                    if failure == 'write' and threading.current_thread() is not threading.main_thread():
                        raise RuntimeError('injected write failure')
                    with lock:
                        balances[int(text.rsplit('=', 1)[1])] += 1
            def query(self, text):
                if failure == 'read' and threading.current_thread() is not threading.main_thread():
                    raise RuntimeError('injected read failure')
                with lock:
                    if text.startswith('SELECT sum'): return Result([(sum(balances),)])
                    if text.startswith('SELECT id'):
                        rows = [(i, b, 256) for i, b in enumerate(balances)]
                        if failure == 'row': rows[0], rows[1] = rows[1], rows[0]
                        return Result(rows)
                    match = re.search(r'id=(\d+)', text)
                    return Result([(balances[int(match[1])] if match else 1,)])

        module = types.SimpleNamespace(TLS=lambda *a: None, Endpoint=lambda *a: None,
                                       connect=lambda *a, **kw: Connection())
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root / 'members.json').write_text(json.dumps([dict(address='x', identity='x')] * 3))
            output = io.StringIO()
            with patch.dict(sys.modules, sqlodin=module), patch.object(
                sys, 'argv', ['worker', name, name, '3']
            ), patch.object(sys, 'path', sys.path.copy()), contextlib.redirect_stdout(output):
                try:
                    exec(compile(WORKER, 'remote-worker', 'exec'), {})
                except BaseException:
                    self.assertNotIn('RESULT ', output.getvalue())
                    raise
            return json.loads(output.getvalue().removeprefix('RESULT '))

    def test_complete_counts_and_replica_rows(self):
        result = self.run_worker()
        self.assertTrue(result['verified'])
        self.assertEqual(result['write_workload']['completed'], 75)
        self.assertEqual(result['write_workload']['writes'], 75)
        self.assertEqual(result['mixed_workload']['completed'], 90)

    def test_failed_write_cannot_report_throughput(self):
        with self.assertRaisesRegex(RuntimeError, 'write failure'): self.run_worker('write')

    def test_failed_read_cannot_report_throughput(self):
        with self.assertRaisesRegex(RuntimeError, 'read failure'): self.run_worker('read')

    def test_same_total_wrong_rows_fail(self):
        with self.assertRaises(AssertionError): self.run_worker('row')


if __name__ == '__main__': unittest.main()
