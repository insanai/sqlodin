#!/usr/bin/env python3
"""Run bounded TLA+ seam checks and named negative controls; never report a timeout as a pass."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
JAR_SHA256 = '71ce43150b6ee0a76cc33849ec45b2c6ae4323dc933b0acaef0928668ed0de72'
CASES = (
    ('ReadCohort', 'ReadCohort', None),
    ('ReadCohort', 'ReadCohortLateJoin', 'Invariant RealTimeOrder is violated'),
    ('ReadCohort', 'ReadCohortEarly', 'Invariant AppliedBeforeSnapshot is violated'),
    ('ReadCohort', 'ReadCohortCancel', 'Invariant MembersHaveBarrier is violated'),
    ('RotatingWindow', 'RotatingConcurrent', None),
    ('RotatingWindow', 'RotatingThreeWindows', None),
    ('RotatingWindow', 'RotatingDown1', None),
    ('RotatingWindow', 'RotatingDown2', None),
    ('RotatingWindow', 'RotatingDown3', None),
    ('RotatingWindow', 'RotatingNoSkip', 'Temporal properties were violated'),
    ('RotatingWindow', 'RotatingNoRevoke', 'Temporal properties were violated'),
    ('RotatingWindow', 'RotatingNoRelease', 'Temporal properties were violated'),
    ('RotatingWindow', 'RotatingReuse', 'Invariant HeldSlot is violated'),
    ('SessionRetirement', 'SessionRetirement', None),
    ('SessionRetirement', 'SessionNoEpochGuard', 'Invariant AtMostOnce is violated'),
    ('SessionRetirement', 'SessionLostEpoch', 'Invariant AtMostOnce is violated'),
    ('SessionRetirement', 'SessionRepeatRetirement', 'Invariant CommandIdempotent is violated'),
    ('SessionRetirement', 'SessionKeepRows', 'Invariant OnlyCurrentRows is violated'),
    ('RestoredGenesis', 'RestoredGenesis', None),
    ('RestoredGenesis', 'GenesisOldNamespace', 'Invariant FreshNamespace is violated'),
    ('RestoredGenesis', 'GenesisMixedImages', 'Invariant CompatibleInitialState is violated'),
    ('RestoredGenesis', 'GenesisEarlyReady', 'Invariant ReadyDurable is violated'),
    ('RestoredGenesis', 'GenesisResetPrefix', 'Invariant RetryOriginsValid is violated'),

    ('ImageRetirement', 'ImageRetirement', None),
    ('ImageRetirement', 'ImageNoSuccessor', 'Invariant LatestQuorumRetained is violated'),
    ('ImageRetirement', 'ImageNoCurrent', 'Invariant ActiveImageRetained is violated'),
    ('ImageRetirement', 'ImageNoPrevious', 'Invariant PreviousImageRetained is violated'),

    ('GenerationRetirement', 'GenerationRetirement', None),
    ('GenerationRetirement', 'RetirementCurrent', 'Invariant CurrentRetained is violated'),
    ('GenerationRetirement', 'RetirementPrevious', 'Invariant PreviousRetained is violated'),
    ('GenerationRetirement', 'RetirementUnowned', 'Invariant UnownedUntouched is violated'),
    ('GenerationRetirement', 'RetirementUnsynced', 'Invariant InventoryComplete is violated'),
    ('GenerationCatalog', 'GenerationCatalog', None),
    ('GenerationCatalog', 'GenerationEarlyPublish', 'Invariant PublishedDurable is violated'),
    ('GenerationCatalog', 'GenerationLostVote', 'Invariant AcceptedSuffix is violated'),
    ('GenerationCatalog', 'GenerationLostPromise', 'Invariant PromiseFence is violated'),
    ('GenerationCatalog', 'GenerationReusedIDs', 'Invariant RequestIDs is violated'),
    ('OwnedSlot', 'OwnedSlot', None),
    ('OwnedSlot', 'OwnedSlotDown1', None),
    ('OwnedSlot', 'OwnedSlotDown2', None),
    ('OwnedSlot', 'OwnedSlotDown3', None),
    ('OwnedSlot', 'OwnedSlotNoDurability', 'Invariant Agreement is violated'),
    ('RecoveryProgress', 'RecoveryProgress', None),
    ('RecoveryProgress', 'RecoveryNoProbe', 'Temporal properties were violated'),
    ('RecoveryProgress', 'RecoveryOneChunk', 'Temporal properties were violated'),
    ('DurableEffects', 'DurableEffects', None),
    ('DurableEffects', 'DurableNoGate', 'Invariant DurableBeforeSend is violated'),
    ('SnapshotPublication', 'SnapshotPublication', None),
    ('SnapshotPublication', 'SnapshotNoGuard', 'Invariant Recoverable is violated'),
    ('ReadFence', 'ReadFence', None),
    ('ReadFence', 'ReadFenceReuse', 'Invariant RealTimeOrder is violated'),
    ('ReadFence', 'ReadFenceNoApply', 'Invariant AppliedBeforeSnapshot is violated'),
    ('SnapshotIdentity', 'SnapshotIdentity', None),
    ('SnapshotIdentity', 'SnapshotMixedKeys', 'Invariant MatchingDurableQuorum is violated'),
    ('SnapshotIdentity', 'SnapshotDuplicateVotes', 'Invariant MatchingDurableQuorum is violated'),
    ('SnapshotIdentity', 'SnapshotVolatileReceipt', 'Invariant MatchingDurableQuorum is violated'),
    ('ManifestDurability', 'ManifestDurability', None),
    ('ManifestDurability', 'ManifestNoFileSync', 'Invariant SuccessSurvives is violated'),
    ('ManifestDurability', 'ManifestNoDirectorySync', 'Invariant SuccessSurvives is violated'),
    ('OwnedSkip', 'OwnedSkip', None),
    ('OwnedSkip', 'OwnedSkipDown1', None),
    ('OwnedSkip', 'OwnedSkipDown2', None),
    ('OwnedSkip', 'OwnedSkipDown3', None),
    ('OwnedSkip', 'OwnedSkipAnyRevoke', 'Invariant LearnedAgreement is violated'),
    ('OwnedSkip', 'OwnedSkipAmnesia', 'Invariant LearnedAgreement is violated'),
    ('OwnedSkip', 'OwnedSkipLearnUnvoted', 'Invariant LearnedAgreement is violated'),
    ('JournalCache', 'JournalCache', None),
    ('JournalCache', 'JournalApplyStaged', 'Invariant AckedRecoverable is violated'),
    ('JournalCache', 'JournalTrimWithoutImage', 'Invariant AckedRecoverable is violated'),
    ('QuorumReadReconnect', 'QuorumReadReconnect', None),
    ('QuorumReadReconnect', 'QuorumReadConnectionCount', 'Invariant RealTimeOrder is violated'),
    ('QuorumRead', 'QuorumRead', None),
    ('QuorumRead', 'QuorumReadApplied', 'Invariant RealTimeOrder is violated'),
    ('QuorumRead', 'QuorumReadNoPeers', 'Invariant RealTimeOrder is violated'),
)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--jar', type=Path, default=os.environ.get('TLA2TOOLS_JAR'))
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--timeout', type=int, default=60)
    p.add_argument('--heap-mib', type=int, default=1024)
    p.add_argument('--workers', type=int, default=1)
    p.add_argument('--case', action='append', dest='selected',
                   help='run a named configuration (repeatable); default: all')
    args = p.parse_args()
    if args.jar is None or not args.jar.is_file():
        p.error('Supply --jar or TLA2TOOLS_JAR (tla2tools v1.6.0, pinned SHA-256)')
    if hashlib.sha256(args.jar.read_bytes()).hexdigest() != JAR_SHA256:
        p.error('TLC artifact hash differs from the reviewed pin')
    if args.output.exists() or args.timeout < 1 or not 256 <= args.heap_mib <= 8192 or not 1 <= args.workers <= 8:
        p.error('Use a new output path, positive timeout, heap 256..8192 MiB and 1..8 workers')
    cases = [case for case in CASES if not args.selected or case[1] in args.selected]
    if args.selected and set(args.selected) - {case[1] for case in CASES}:
        p.error('Unknown configuration name')
    report = dict(complete=False, passed=False, scope='bounded owned-decree and host-seam models; not a full multi-slot refinement proof',
                  tlc_sha256=JAR_SHA256, heap_mib=args.heap_mib, workers=args.workers, cases=[])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix='sqlodin-tlc-') as name:
            for module, cfg, expected in cases:
                command = ['java', '-XX:+UseParallelGC', f'-Xmx{args.heap_mib}m', '-cp', str(args.jar.resolve()),
                           'tlc2.TLC', '-deadlock', '-workers', str(args.workers), '-metadir', str(Path(name) / cfg),
                           '-config', cfg + '.cfg', module + '.tla']
                started = time.monotonic()
                case = dict(model=module, config=cfg, expected_violation=expected, passed=False,
                            sources={f: hashlib.sha256((ROOT / 'specs' / f).read_bytes()).hexdigest()
                                     for f in (module + '.tla', cfg + '.cfg')})
                report['cases'].append(case)
                try:
                    result = subprocess.run(command, cwd=ROOT / 'specs', capture_output=True,
                                            text=True, timeout=args.timeout)
                except subprocess.TimeoutExpired as exc:
                    output = exc.stdout or b''
                    case.update(seconds=time.monotonic() - started, timed_out=True,
                                output=output.decode(errors='replace') if isinstance(output, bytes) else output)
                    raise
                out = result.stdout + result.stderr
                case.update(seconds=time.monotonic() - started, exit_code=result.returncode, output=out)
                if expected:
                    case['passed'] = result.returncode in (12, 13) and expected in out
                else:
                    case['passed'] = (result.returncode == 0 and
                                      'Model checking completed. No error has been found.' in out and
                                      re.search(r'0 states left on queue', out) is not None)
                print(('PASS ' if case['passed'] else 'FAIL ') + cfg, flush=True)
                if not case['passed']:
                    raise RuntimeError(f'Formal check {cfg} did not produce its required result')
        report.update(complete=True, passed=True)
    except BaseException as exc:
        report['error'] = repr(exc)
        raise
    finally:
        args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
