#!/usr/bin/env python3
"""Derive resource and target observations from retained R6 samples; never relabel a miss."""
import argparse
import hashlib
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('matrix', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert not args.output.exists(), 'Preserve earlier evidence'
    matrix = json.loads(args.matrix.read_text())
    report = dict(complete=False, matrix_sha256=hashlib.sha256(args.matrix.read_bytes()).hexdigest(),
                  original_targets=matrix['originals'], cases=[],
                  qualifications=[
                      'CPU and /proc I/O differences cover the measured workload interval.',
                      'Forwarded sync and pwrite counters include setup, validation and shutdown.',
                      'Write-byte ratio compares three replicas combined with a single SQLite reference.',
                      'Reference uses the same pinned FULL SQLite and bounded grouping, without TLS or replication.',
                      'Scheduled latency includes backlog; bounded clients are not an unlimited arrival generator.',
                      'Throughput and latency targets are evaluated, not weakened or claimed as guarantees.'])
    for index, entry in enumerate(matrix['cases']):
        path = args.matrix.with_suffix('')/f'case-{index:02d}.json'
        assert hashlib.sha256(path.read_bytes()).hexdigest() == entry['sample_sha256']
        source = json.loads(path.read_text())
        case = source['cases'][0]
        assert source['complete'] and case['verified'] and case['sqlite_verified']
        native, reference = case['sqlodin'], case['sqlite']
        result = dict(index=index, parameters=entry['parameters'], sample_sha256=entry['sample_sha256'],
                      native_tps=native['per_second'], sqlite_tps=reference['per_second'],
                      completed=native['completed'], offered=native['offered'], errors=native['errors'],
                      latency_ms=native['latency_ms'], latency_basis=native['latency_basis'])
        result['successful_writes'] = sum(op['write'] and op['status'] == 'ok' for op in native['raw'])
        result['writes_per_second'] = result['successful_writes']/native['elapsed']
        result['cpu_cores'] = sum(case['after']['nodes'][n]['cpu_seconds']-
                                  before['cpu_seconds'] for n,before in case['before']['nodes'].items())/native['elapsed']
        result['peak_voter_rss_bytes'] = max(node['rss_bytes'] for sample in
            [case['before'], *case['samples'], case['after']] for node in sample['nodes'].values())
        result['proc_write_bytes'] = sum(case['after']['nodes'][n]['io']['write_bytes']-
            before['io']['write_bytes'] for n,before in case['before']['nodes'].items())
        profiles = list(case['io_profiles'].values())
        calls = sum(p['sync_calls'] for p in profiles)
        result['whole_process_sync_calls'] = calls
        result['whole_process_mean_sync_ms'] = sum(p['sync_ns'] for p in profiles)/calls/1e6
        result['whole_process_write_byte_ratio'] = sum(p['write_bytes'] for p in profiles)/case['sqlite_io_profile']['write_bytes']
        result['max_final_history_bytes'] = max(s['history_bytes'] for s in case['frontiers_after']['nodes'].values())
        result['sqlite_fraction'] = native['per_second']/reference['per_second']
        goals = report['original_targets']
        result['targets_met'] = dict(sqlite_fraction=result['sqlite_fraction'] >= goals['sqlite_fraction'])
        for kind in ('read', 'write'):
            if kind in native['latency_ms']:
                result['targets_met'][kind+'_p99'] = native['latency_ms'][kind]['p99'] <= goals[kind+'_p99_ms']
        if case['read_percent'] == 70:
            result['targets_met']['mixed_tps'] = native['per_second'] >= goals['mixed_tps']
            result['targets_met']['mixed_writes_per_second'] = result['writes_per_second'] >= 900
        if case['read_percent'] == 0:
            result['targets_met']['pure_write_tps'] = native['per_second'] >= goals['write_tps']
        report['cases'].append(result)
    report['complete'] = matrix['complete']
    report['operations_verified'] = sum(c['completed'] for c in report['cases'])
    report['all_applicable_targets_met'] = all(all(c['targets_met'].values()) for c in report['cases'])
    args.output.write_text(json.dumps(report, indent=2)+'\n')


if __name__ == '__main__':
    main()
