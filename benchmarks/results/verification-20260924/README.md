# Verification evidence, 24 September 2026

This directory preserves separate runs; it is not a single production-qualification pass.

| Evidence | Result and boundary |
|---|---|
| `formal-models-manifest.json` | Latest 22 TLC configurations: ten positive checks and twelve required counterexamples. Includes all earlier model cases. Models have explicit bounded/abstract scope. |
| `formal-models-snapshot-identity.json` | Earlier 19-configuration run, retained unchanged. |
| `formal-models-read-fence.json` | Earlier 15-configuration run, retained unchanged. |
| `formal-models.json` | Earlier 12-configuration run, retained unchanged. |
| `formal-proofs.json` | Twelve TLAPS obligations for the abstract unbounded durable-history invariant. Does not prove Paxos agreement or Odin refinement. |
| `verification.log` | Upstream: 81 tests in two profiles and 180 seeded fault simulations, totaling 1.8 million steps. |
| `all-tests.log`, `debug-tests.log` | SQLodin: 96 tests per Linux profile before the added stale-reader regression. |
| `read-fence-local.json`, `read-fence-linux.json` | New stale-reader regression, local debug and Linux optimized builds; both passed. |
| `all-tests-certificate-linux.json` | Expanded 98-test optimized Linux suite before the certificate codec was added. |
| `all-tests-snapshot-codec-linux.json` | Final expanded 99-test optimized Linux suite, using project disk directories; all passed. |
| `all-tests-snapshot-image-linux.json` | Expanded 102-test Linux suite including pinned image copying and failure cleanup; all passed. |
| `all-tests-snapshot-verifier-linux.json` | Latest 105-test optimized Linux suite, including manifest storage and file/integrity verification; all passed. |
| `snapshot-verifier-local.json` | Four focused local debug regressions for image/manifest verification and storage failures; all passed. |
| `snapshot-codec-local-final.json` | Two focused local debug tests: certificate quorums/identity and codec framing/corruption, including the independent digest vector. |
| `network-final.json` | Final binary, three Linux processes on `.18`, 14 native-service checks. |
| `network-final-three-host.json` | Final binary on `.19/.20/.21`, 12 native-service checks. |
| `majority-local.json`, `majority-linux.json` | Each voter absent in turn; both survivors receive direct requests, rejoin exceeds the active window, final full restart. Local: 90 operations per failure. Linux: 240. |
| `saved-recovery-final.json` | Final binary replays isolated copies of the failed campaign's databases across the three instances; fresh quorum-backed reads succeed. |
| `saved-recovery-final-audit.json` | Stopped-copy exact workload/integrity audit and matching application/session hashes. Original acknowledgement history is not reconstructed. |
| `bench-baseline.json`, `bench-progress.json` | Matched `.18` on-disk FULL mixed and sequential workloads, three repetitions each. Healthy medians improve; degraded-mode medians regress. |

`network-initial-local.json` and `saved-recovery-initial.json` are earlier-candidate evidence.
Their binary hashes differ from the final Linux candidate:
`1559fc9c2c3cd6b6f93e83c564d92b0d21f2b59a097a3f7d083c0f4601418fcd`.
The pinned whole upstream commit is `c3d197016c1f938db23fdf7f1fe87fbdbb86ac1c`;
it is published on GitHub branch `sqlodin/bounded-ownership-progress` with explicit user approval.

See [the specification contract](../../../specs/README.md) for assumptions and open proof obligations,
and [the implementation ledger](../../../docs/implementation-status.md) for unimplemented work.
JSON is consumed directly by the book. Earlier results are retained rather than relabeled.
`upstream-publication.json` records the approved branch push and exact remote commit verification.
The earlier source manifest records the then-unpublished state and is retained as historical evidence.
