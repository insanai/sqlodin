#!/usr/bin/env python3
"""Bind already-passing formal checks to unchanged current sources; report any missing case."""
import argparse
import hashlib
import json
from pathlib import Path

from check_formal import CASES, JAR_SHA256
from check_proofs import SHA256 as PROOF_SHA256, VERSION as PROOF_VERSION

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--evidence', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    assert not args.output.exists()
    reports = []
    for path in sorted(args.evidence.glob('formal*.json')):
        try:
            reports.append((path, json.loads(path.read_text())))
        except (ValueError, OSError):
            continue
    result = dict(complete=False, cases=[], proofs=[], missing=[],
                  scope='reuse only source-identical successful checks; not a new TLC/TLAPS execution',
                  collector_sha256=sha(Path(__file__)))
    for model, config, expected in CASES:
        sources = {name:sha(ROOT/'specs'/name) for name in (model+'.tla',config+'.cfg')}
        matches = []
        for path, report in reports:
            if report.get('tlc_sha256') != JAR_SHA256:
                continue
            for case in report.get('cases',[]):
                if (case.get('model') == model and case.get('config') == config and
                    case.get('sources') == sources and case.get('passed') and
                    case.get('expected_violation') == expected and not case.get('timed_out')):
                    code, output = case.get('exit_code'), case.get('output','')
                    valid = code in (12,13) and expected in output if expected else (
                        code == 0 and 'No error has been found' in output and '0 states left' in output)
                    if valid:
                        matches.append(dict(report=str(path), report_sha256=sha(path)))
        if not matches:
            result['missing'].append(config)
        result['cases'].append(dict(model=model, config=config, sources=sources,
                                    expected_violation=expected, evidence=matches[:1]))
    for model, obligations in (('DurableHistoryProof',12),('PrefixRecoveryProof',36)):
        source = sha(ROOT/'specs'/f'{model}.tla')
        matches = [dict(report=str(path),report_sha256=sha(path)) for path, report in reports
                   if report.get('model',model) == model and report.get('source_sha256') == source and
                   report.get('distribution_sha256') == PROOF_SHA256 and
                   report.get('tool_revision') == PROOF_VERSION and
                   report.get('passed') and report.get('exit_code') == 0 and
                   report.get('obligations') == obligations and
                   f'All {obligations} obligations proved' in report.get('output','')]
        if not matches:
            result['missing'].append(model)
        result['proofs'].append(dict(model=model, source_sha256=source,
                                     obligations=obligations, evidence=matches[:1]))
    result['complete'] = not result['missing']
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(len(result['cases']), 'model cases;', sum(p['obligations'] for p in result['proofs']),
          'inductive obligations; missing:', result['missing'])
    if not result['complete']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
