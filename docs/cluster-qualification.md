# Three-instance, eight-hour qualification campaign

Vikrant Rathore, with assistance from Ronak Rathore. Updated 2026-09-23.

## Current native-service run

A fresh eight-hour run of the format-4 / policy-6 native mTLS service started at
**2026-09-23 02:04:16 UTC (10:04 Singapore time)**. Its workload is scheduled to end
at **10:04:16 UTC (18:04 Singapore time)**, followed by final all-voter restart and
offline integrity/hash checks. This is **in progress, not passed**. The old failed
run below remains separate evidence.

The coordinator runs detached on `.19`; consensus and SQL use direct mTLS among
`.19`, `.20` and `.21`. SSH only controls test processes and retrieves audits.
The coordinator's run-specific SSH key is restricted to `.19`, a fixed supervisor
command and an expiry; successful cleanup removes its authorization. Supervisors
check an absolute deadline and sample 512 MiB RSS, 8 GiB data and 10 GiB minimum
free-space guards every two seconds; they stop the voter on a violation. These
sampled guards are not kernel-level storage reservations or strict RSS ceilings.
A voter is killed if its supervisor dies. No laptop process is needed to keep the
soak running. Each run uses new directories and preserves previous databases.

The fixture runs 70/30 point reads and atomic transfers with twelve long-lived
sessions, generated balances, indexed transfer/ledger checks, cross-master duplicate
retries, hourly rotating voter SIGKILL/reopen, and a final full-cluster restart.
It then compares complete offline application hashes and integrity across nodes.
The corrected verifier bounds both sides of its ledger join. This is a bounded
mixed-SQL endurance test, not a complete ORM endurance or history-linearizability audit.

The 65-second pilot passed 917 operations, three rotating voter failures and final
recovery/hash checks. A second 45-second pilot exercised supervised startup/recovery
and automatic SSH authorization cleanup; resource thresholds were configured, not
deliberately exceeded. The identical tested Linux binary is SHA-256
`de7fa66bef035c65ce68041a9bad595517b0ade5b71cbbe5a7ef40483bfb3a5e`.

Live results on `.19`:
`/home/insan/projects/sqlodin/native-soak/20260923T020409Z-eight-hour/soak.json`.
The checked-in copy under `benchmarks/results/native-soak-20260923T020409Z/` is a
snapshot. Refresh only the result files, not the private keys:

```sh
rsync -az \
  insan@10.175.52.19:/home/insan/projects/sqlodin/native-soak/20260923T020409Z-eight-hour/soak.json \
  insan@10.175.52.19:/home/insan/projects/sqlodin/native-soak/20260923T020409Z-eight-hour/soak.jsonl \
  benchmarks/results/native-soak-20260923T020409Z/
```

Reproduction uses `tools/launch_native_soak.py`, `tools/run_native_soak.py` and
`tools/native_soak_worker.py`. `python3 tools/launch_native_soak.py 28800 eight-hour`
creates a new isolated run; do not launch it while another run occupies port 27701.
All comparative benchmark runs now use `.18`, separately from these soak hosts.

## Earlier SSH-fixture run: failed

The authorized campaign uses `insan@10.175.52.19` (`agy01`),
`insan@10.175.52.20` (`agy02`) and `insan@10.175.52.21` (`agy03`).
Each runs one identical optimized Odin voter in its own persistent directory.
All instances report LXC virtualization and ZFS-backed root filesystems. Distinct
instance identities are checked; independent physical machines, storage devices
and power domains have **not** been established.

The workload started at **2026-09-22 17:06:06 UTC** and stopped at
**18:32:01 UTC**, after about 85 minutes. **The eight-hour qualification failed**:
a per-minute transfer/ledger verification query exceeded the read instruction
budget (`Query_Limit`). The final periodic sample recorded 329,064 operations.
The run did not reach its scheduled end or final recovery phase.

A subsequent read-only audit found SQLite integrity OK on all three instances,
100,105 transfers and 200,210 ledger rows each, exact generated transfers/balances,
and identical hashes for application, session and applied-state tables. Evidence is
in `post-failure-audit.json`. This audit does not replace the missing endurance run
or prove every client acknowledgement from a complete history.

A read-only diagnostic linked against the exact pinned SQLite 3.51.3 reproduced
the whole-ledger scan: over 1,006,000 VM instructions for 32 transfer IDs. Adding an
explicit `l.tx BETWEEN start AND end` condition selects the existing ledger index
and returns the same 32 rows using about 3,000 instructions. The runner now uses
that bounded range; the read limit remains unchanged. This is verified by
`pinned-query-diagnosis.json`; it does not establish a successful soak rerun.
The original failure report and frozen source remain intact. The 24-hour and
seven-day campaigns have not been started.

These durations and topology requirements are SQLodin-specific release goals.
An unrun test is missing evidence, not by itself a demonstrated software defect.

## Evidence and reproduction

The coordinator directory is:

```text
/home/insan/projects/sqlodin/qualification/20260922T165016Z
```

The same root exists on the other two instances. Voter databases live in
`soak/node.db`; smoke and pilot databases remain in separate directories.
`results/soak.json` is atomically updated with status and the latest sample.
`results/soak.jsonl` retains per-minute observations and fault events.
`soak-launch.log`, transport logs and each voter's `stderr.log` retain failures.
`manifest.json` records source, binary, dependency and prerequisite evidence.
The original preflight sources are retained in `preflight-source.tar.gz`.

Local evidence is collected under
[`benchmarks/results/linux-three-host-20260922T165016Z/`](../benchmarks/results/linux-three-host-20260922T165016Z/).
It is a fetched snapshot, not a live view. Refresh it with:

```sh
rsync -az \
  insan@10.175.52.19:/home/insan/projects/sqlodin/qualification/20260922T165016Z/results/ \
  benchmarks/results/linux-three-host-20260922T165016Z/
```

The runner is `tools/run_cluster_soak.py`; the restricted remote supervisor is
`tools/qualification_worker.py`. Deploy a fresh root and new configuration for
each run. Never point `create` at an existing voter directory, recreate a missing
voter under its old identity, or overwrite a prior result. The current deployment
uses an expiring key restricted to the coordinator IP and this supervisor, with
strict SSH host-key verification. It does not install a general-purpose remote
shell key. Only the three named test directories are modified by the supervisor.
The two newly provisioned instances presented the same pre-existing SSH host key;
this campaign preserves that configuration. It therefore does not demonstrate
independently provisioned per-node transport identities. Native mTLS enrollment
must generate distinct private keys on each joining instance.

## What this run exercises

- Twelve long-lived transfer sessions, plus one schema session. Each has one
  outstanding request and monotonically increasing sequences. This tests reuse
  without exhausting the 65,536-session bound by creating a client per write.
- A 70% read / 30% transfer generator with a 256-byte payload, three accounts,
  primary/foreign/CHECK constraints, an index and a two-row audit trigger.
- Direct admission through all three voters. Writes and ordered read barriers
  travel over authenticated SSH channels through a parallel coordinator.
- Per-minute exact transfer/audit checks, fenced balance checks, and acknowledged
  retries through another voter before advancing the same client session.
- Hourly voter SIGKILL/reopen, rotating the victim, followed by a fresh read.
  The separate preflight smoke also checks minority isolation, surviving-quorum
  writes, uncertain retries, stale-voter reads and catch-up.
- A final whole-cluster SIGKILL/reopen, matching applied prefixes, then offline
  read-only integrity/foreign-key checks and streamed hashes of all application
  rows, audit rows, session fences and applied state. Every transfer and final
  account balance is independently checked against the generated ID rule.

The fixture uses the existing durable engine unchanged, including FULL commits.
The binary hash is checked on every instance before a run. The matching source
snapshot previously passed all 22 disk-crash cases. The three-host preflight
passed all nine workload/fault checks, and the 125-second pilot passed 10,140
operations (7,115 reads and 3,025 transfers), final recovery and equal state hashes.

## Bounds and interpretation

Each supervisor stops its voter above 512 MiB resident memory or 8 GiB of total
test database/WAL files, or below 10 GiB free filesystem space. These are sampled
guards, not kernel-level storage reservations. The child has a 2 GiB address-space
limit. EOF, supervisor death, the absolute host deadline and coordinator timeouts
bound orphan processes. An hourly or final recovery taking longer than the
45-second controller RPC deadline fails the run rather than hanging indefinitely.

Reports include actual remote voter CPU, RSS/high-water RSS, database/WAL bytes,
free space, interval throughput and per-interval latency percentiles. Coordinator,
SSH, Python framing and verification contribute to wall time; voter CPU excludes
those processes. This is a closed-loop, small hot-account workload. It is not
an offered-load saturation test, a large-dataset capacity result, a physical
power-loss test or the production network service. Short separate mTLS build/tests
also ran on the coordinator during the campaign; this is not an isolated
performance calibration environment.

Native mTLS work lives separately in `transport/mtls` and does not modify the
frozen source snapshot. See [the transport implementation boundary](mtls.md).
