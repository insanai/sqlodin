# SOD 0005 evidence

Reports for [SOD 0005](../../../docs/sod/records/0005-durable-turn-and-fast-skip-learning.typ).
The baseline binary is built from the unmodified parent revision
(sha256 `aa36f6bbe368fd42b0e59fcfe98cc3f5a65cf41dd4937a5c6a3a7e2ac19a5769`); the candidate
binary is sha256 `245b6c36b7a1b67e474b7944af97262838d562504fb6f956d00125798ef89359`.

- `calibration-baseline.json`, `calibration-sod0005.json`: `tools/calibrate_native_mixed.py`
  on `.18`, clients 1/8/32, 70% and 0% reads, 100 operations per client, SQLite FULL with groups
  of at most 16, measured in the same run.
- `three-host-comparison.json`: `tools/compare_three_hosts.py`, voters on `.19`/`.20`/`.21`,
  client on `.18`, baseline and candidate alternating for three repetitions.
- `three-host-comparison-32.json`: the same comparison with `--clients 32`.
- `three-host.json`: `tools/check_network_hosts.py --majority` on the candidate.
- `service/`: network-service, transaction-history (two seeds), ORM, majority, session-crash,
  snapshot, catch-up, admission, Python and CLI checks on the candidate.
- `formal/`: `tools/check_formal.py` (72 cases) and `tools/check_proofs.py` (three proofs).
- `check-summary.log`: pass lines from the full `tools/check.py` gate, plus both service-check
  attempts. The first attempt's history/ORM/Python/CLI failures were environmental: SQLAlchemy was
  missing from the system Python, and the shell path was wrong. The second attempt passed.

`.18` shares one ZFS intent log among the three local voters, and its sync latency varies with
other tenants. Compare ratios only within one report.

Review caveat: the original three-host comparison worker did not propagate thread exceptions.
Its recorded throughput cannot independently establish that every scheduled operation completed.
Those reports remain unchanged. The corrected worker fails on exceptions, counts completions,
and verifies every account row; SOD 0005 records review evidence separately. The calibration
harness already propagates future exceptions and is unaffected by this specific defect.

`review/three-host-comparison-32.json` is a fresh corrected-harness pair, with 800 completed
pure-write and 960 completed mixed operations per binary and every replica row verified.
It is a short regression measurement, not a sustained-capacity qualification.
