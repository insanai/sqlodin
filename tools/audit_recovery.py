#!/usr/bin/env python3
"""Audit a completed, stopped three-host recovery replay without changing its report."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from check_network_hosts import SSH


def audit_replicas(recovery):
    if not recovery.get('complete') or not recovery.get('passed'):
        raise ValueError('A completed recovery replay is required')
    root = Path(recovery['remote_root'])
    if root.parent != Path('/home/insan/projects/sqlodin/recovery-replay'):
        raise ValueError('Expected an isolated recovery-replay directory')
    worker = Path(__file__).with_name('qualification_worker.py')
    source = worker.read_text()
    results = []
    for host in recovery['hosts']:
        # Execute the existing streamed, exact transfer verifier without its CLI.
        # Reject any live PID, including PID reuse: being conservative is safe.
        script = "__name__ = 'recovery_audit'\n" + source + f'''
root = Path({str(root)!r})
pid = (root/'server.pid').read_text().strip()
if not pid.isdecimal() or (Path('/proc')/pid).exists():
    raise RuntimeError('Recovery voter PID is live or invalid; stop it before auditing')
print(json.dumps(audit(root, 'data')))
'''
        run = subprocess.run([*SSH, host, 'python3 -'], input=script,
                             capture_output=True, text=True, check=True, timeout=180)
        result = json.loads(run.stdout)
        result['host'] = host
        results.append(result)
    # Read barriers can advance internal applied watermarks without modifying SQL
    # rows. Compare application data and durable request identities, not those
    # watermarks. The complete audit still records each internal-state digest.
    compared = ('accounts', 'transfers', 'ledger', 'sessions')
    for result in results:
        for table in compared:
            if result['logical_sha256'][table] != results[0]['logical_sha256'][table]:
                raise ValueError(f'Replica mismatch in {table}: {result["host"]}')
        expected = {node['transfers'] for node in recovery['nodes'].values()}
        if expected != {result['counts']['transfers']}:
            raise ValueError('Offline transfer count differs from the live replay')
    return dict(complete=True, passed=True, remote_root=str(root), audits=results,
                compared_tables=compared, verifier_sha256=hashlib.sha256(source.encode()).hexdigest())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--recovery-report', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Use a new output path; retain earlier evidence')
    report = dict(complete=False, passed=False,
                  recovery_report_sha256=hashlib.sha256(args.recovery_report.read_bytes()).hexdigest())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        report.update(audit_replicas(json.loads(args.recovery_report.read_text())))
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        args.output.write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
