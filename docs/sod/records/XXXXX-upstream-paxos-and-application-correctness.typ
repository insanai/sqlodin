#let sod-number = "XXXXX"
#let sod-title = "Pinned Upstream Paxos and SQLite Application Correctness"
#let sod-state = "prediscussion"
#let sod-created = "2026-09-22"
#let sod-discussion = "Implementation review"
#let sod-labels = ("consensus", "storage", "performance")
#let sod-authors = ("Vikrant Rathore, with assistance from Ronak Rathore",)
#let sod-category = "Engineering Discussion"
#let sod-status = "Draft; implementation under review"
#let sod-last-updated = "2026-09-22"
#import "../../shared/sod.typ": sod-document
#show: doc => sod-document(
  sod-number, sod-title, doc, authors: sod-authors, state: sod-state,
  created: sod-created, discussion: sod-discussion, labels: sod-labels,
  category: sod-category, status: sod-status, last-updated: sod-last-updated,
)

= Scope and Implementation Boundary

Import the complete paxos-odin repository as a Git submodule at
`a3e1fd78ec8f0429e5024710189ef77fc31961af`. Remove SQLodin's partial protocol copy.
A thin adapter forces rotating ownership and passes initialization, restoration, stepping,
proposals and ticks to upstream. Consensus errors retain upstream types and explanations;
SQLite errors remain local. Changes to the pin require both libraries' test suites to pass.

This draft records implemented changes under review. It does not certify a production host,
power-loss durability, arbitrary SQL determinism, or comparative WAN performance.

= Application Transactions

Apply contiguous decided batches within an explicit SQLite transaction. Roll back on any failure;
commit user data and `_sqlodin_state.applied` together. Restore this watermark on opening the database.
Reject gaps, unknown mutation kinds and malformed lengths. Replayed applied slots are ignored.
Use FULL synchronization for file-backed SQLite. Persist consensus promises and votes separately.

Cache eight DML statements per engine. Borrow immutable text/vector payloads with explicit byte lengths;
reset statements and clear bindings before returning. Match cached statements directly by bounded
table/column metadata so a hit does not format SQL. Check bind, step, begin and commit results.
Implement updates and vector BLOB binding rather than silently ignoring them.

Raw SQL cannot control transactions, attach databases, issue state-changing PRAGMAs or alter the internal watermark.
The host still guarantees deterministic statements and schema behavior. A failed decided mutation blocks
application. No automatic skipping or exactly-once guarantee is introduced.

= Memory and Identifier Bounds

Use one shared fixed vector payload per mutation instead of reserving 384 floats in each column.
The default total budget is 384 floats, configurable at compile time. This changes Mutation's in-memory
layout; native struct bytes are not a versioned wire/storage format. A production codec must define its
own stable format and bounds checks. Text, column names and vector offsets are validated before slicing.

Snowflake engine IDs use logical milliseconds on sequence overflow or clock rollback. Reject out-of-range
IDs/timestamps rather than masking them. A host must persist the issued logical timestamp frontier before
reusing its node identity after restart.

= Validation and Performance Claims

Use the pinned upstream tests, SQLodin regression tests, and a bounded network simulator with copied
payloads, drops, duplication, reorder and ledger restoration. Compare actual applied data and decisions,
not the number of result rows returned by `SELECT count(*)`. Example and benchmark errors are fatal.

Measure only successful replicated SQLite writes. Include every replica's SQL application and message
payload copies. Report a matched single-leader workload, timing boundaries, payload/node sizes and sample
ranges. Withdraw earlier throughput and fixed WAN penalty claims. No comparative service advantage is established.

= Remaining Production Work

The fixed-membership durable journal/codec, historical range service and Linux disk-backed benchmarks
are now implemented. A production network service, certified snapshots,
the complete deterministic-SQL contract and a matched distributed service benchmark remain work.
Format-2 transaction outcomes, bounded session deduplication and a function policy are now implemented;
see the production SOD and `docs/implementation-status.md` for remaining gates.
The production SQL and durable throughput SOD defines the next acceptance gates. Existing theoretical documents specify assumptions; they do not
prove those host obligations are implemented.


= Linux Measurement Follow-up

The historical memory report built SQLite 3.50.4 and sqlite-vec 0.1.9 from verified source/header hashes on Linux. The current durable Linux build pins SQLite 3.51.3. Keep native
artifacts under build/native, separately from the macOS archive. Run the full verification suite,
then seven shuffled rounds of reference, shape-cache-only and optimized builds, each comparing
single-leader, multi-master and local SQLite application. Record raw samples, latency percentiles,
per-child CPU/RSS, compiler flags, system metadata and source/binary digests as JSON. The book
loads that result file directly. The growing FIFO starts with 32 packets instead of 256.

These measurements are memory-only and single-threaded. They do not measure durable service,
network, WAN or multi-core performance, and cannot establish comparative service performance.
