# sqlodin

Distributed Multi-Master SQLite via Rotating Paxos Consensus in Odin.

[Book](docs/build/sqlodin-book.pdf) | [SOD Records](docs/build/sod-index.pdf) | [Bundle](docs/build/sod-bundle.pdf) | [License](LICENSE)

The toolchain CLI is **sqlodin**; the Odin package is **sqlodin**.  
Authored by **Vikrant Rathore**, with assistance from **Ronak Rathore**.  
Copyright (c) 2026 Vikrant Rathore and Ronak Rathore, under the MIT License.

---

## Why SQLodin?

Replicated SQLite systems historically struggled with concurrent multi-master writes.
Implementations like Zaxonlite (`paxos-zig`) achieved replication by broadcasting raw 4KB Write-Ahead
Log (WAL) page frames. Because concurrent physical page writes to SQLite B-trees cause instant and
irreversible page corruption, Zaxonlite was forced to funnel all writes through a single leader node.
Across geographic regions, this single-leader hop imposed a **~42 millisecond forwarding penalty**
on every write initiated from a replica.

**SQLodin eliminates the 42ms penalty entirely.**

By shifting the consensus abstraction layer from physical page frames to **deterministic logical mutations**
and employing **rotating slot ownership** (Mencius-style log partitioning), every node in a SQLodin
cluster acts as a master capable of committing writes directly in **1 RTT** to peer quorums with
**zero forwarding penalty**.

Additionally, SQLodin natively embeds `sqlite-vec` alongside `FTS5`, delivering hardware-accelerated
dense vector similarity search (KNN cosine and L2 distance) and full-text search directly inside
the replicated relational database.

---

## Quick Facts

- **Multi-Master Fast Path:** Rotating slot ownership ($S \equiv \text{node\_id} \pmod N$) allows
  any node to propose in round 0 and commit in **1 RTT** with **0.00ms forwarding penalty**.
- **Deterministic Logical Mutations:** Replicates structured transaction descriptors (`Insert`,
  `Delete`, `Update`, `Raw_SQL`, `Skip`) rather than raw page frames.
- **Conflict-Free Primary Keys:** Integrated 64-bit Snowflake generator (`42-bit timestamp`,
  `10-bit node_id`, `12-bit sequence`) prevents primary key collisions across concurrent writers.
- **Idempotent Deletes:** Out-of-order and concurrent deletions execute safely without constraint failure.
- **Vector & Full-Text Search:** Native static integration of `sqlite-vec` (`vec0`) and `FTS5` virtual
  tables for AI embedding search and hybrid BM25 full-text querying.
- **Pure State Machine:** Consensus core executes with **zero heap allocations** and **no I/O**.
- **Durability Gate:** Enforces that ledger writes are persisted and synced before network transmission.
- **Read-Your-Writes Watermarks:** Monotonic slot watermarks provide casual consistency for local snapshot reads.
- **Elm-Style Diagnostics:** Every error returned features a formatted `-- BANNER --`, human-readable
  explanation, and a actionable `Hint:`.
- **Architectural Rigor:** Governed by the Zen of Odin for InsanAI (SOD-0001): files $\le$ 1,408 lines,
  columns $\le$ 108 (soft 99), procedure logic $\le$ 70 statements.

---

## Performance Benchmark

Measured on Apple Silicon (M-series) running 3 concurrent multi-master nodes:

```
================================================================================
  SQLODIN PERFORMANCE BENCHMARK
================================================================================
Running 10,000 iterations across 3 multi-master nodes...

Multi-Master Writes:    762,195.42 ops/sec   ( 1.312 us/op)
  Forwarding penalty:   0.000 ms (0 WAN hops, direct 1-RTT local commit)
  Single-leader penalty avoided: ~42.000 ms per remote write

sqlite-vec KNN Search:   27,015.11 queries/sec (37.016 us/query)
FTS5 Full-Text Match:    95,307.24 queries/sec (10.492 us/query)
================================================================================
```

---

## Getting Started

### Prerequisites
- **Odin:** `dev-2026-09` or newer.
- **SQLite:** System SQLite3 with FTS5 enabled (`brew install sqlite` on macOS).
- **Python 3:** For the verification toolchain.
- **Typst:** `0.13.0` or newer for building documentation.

### Bootstrap Build
```bash
./build.sh
```

Or build directly via `make`:
```bash
make build
```

---

## Quick Example

Run the 3-node multi-master search demo:
```bash
make example
```

```odin
package main

import "core:fmt"
import sqlodin "path/to/sqlodin/src"

main :: proc() {
    // 1. Open SQLite engine with WAL and sqlite-vec
    e, _ := sqlodin.engine_open(":memory:", 1, memory = true)
    defer sqlodin.engine_close(&e)

    // 2. Initialize schema
    sqlodin.engine_exec(&e, "CREATE VIRTUAL TABLE docs USING fts5(title, body);")
    sqlodin.engine_exec(&e, "CREATE VIRTUAL TABLE doc_vecs USING vec0(emb float[4]);")

    // 3. Propose local write into owned slot (1-RTT fast path)
    // Primary keys use 64-bit Snowflake IDs to eliminate collisions
    pk := sqlodin.engine_next_id(&e, 1000)
    m, _ := sqlodin.mutation_make_insert(1, 1000, pk, "docs")
    sqlodin.mutation_add_text(&m, "title", "Paxos in Odin")
    sqlodin.mutation_add_text(&m, "body", "Zero latency multi-master SQLite")

    // Apply committed slot to local SQLite WAL state machine
    sqlodin.engine_apply_slot(&e, 1, &m)

    // 4. Query with FTS5 and sqlite-vec
    rows, _ := sqlodin.engine_read_snapshot(&e, "SELECT * FROM docs WHERE docs MATCH '\"multi-master\"';")
    fmt.printf("Matched %d document(s).\n", rows)
}
```

---

## Repository Layout

```
sqlodin/
├── src/                # Pure consensus and SQLite engine core
│   ├── ballot.odin     # 64-bit packed ballot arithmetic
│   ├── bit_set.odin    # Fixed-capacity bitset backed by 64-bit words
│   ├── membership.odin # Cluster membership, quorums, binary search
│   ├── mutation.odin   # Deterministic mutations and Snowflake ID generator
│   ├── ledger.odin     # Struct-of-Arrays (SoA) ledger columns
│   ├── messages.odin   # Wire messages, envelopes, and skip decrees
│   ├── effects.odin    # Pure effect transitions and Durability_Gate
│   ├── node.odin       # MultiMaster_Node participant
│   ├── consensus.odin  # Phase 2 fast-path commit and state transitions
│   ├── ownership.odin  # Rotating slot ownership, 1-RTT proposals, idle skips
│   ├── engine.odin     # Continuous SQLite WAL state machine application
│   ├── errors.odin     # Elm-style error diagnostics with Hint:
│   ├── sqlodin.odin    # Top-level API exports
│   └── sqlite/         # SQLite C-bindings and static sqlite-vec archive
├── cli/                # The `sqlodin` developer toolchain CLI
├── tests/              # 19 comprehensive unit tests across 11 suites
├── sim/                # Chaos simulator with packet drops, reordering, and convergence checks
├── bench/              # Multi-master write, sqlite-vec, and FTS5 microbenchmarks
├── examples/           # Multi-master search demo with FTS5 and vector similarity
├── docs/               # Typst specification book and SOD records
│   ├── book/           # Architectural book chapters (00 through 07)
│   ├── sod/            # SQLodin Discussion RFCs (SOD-0001, SOD-0002)
│   └── build/          # Compiled PDF specifications
└── tools/              # Verification scripts (check.py, check_contracts.py, check_style.py)
```

---

## Verification & Toolchain

SQLodin includes a rigorous CI test runner:

```bash
# Run all unit tests (debug and release)
make test

# Run style checks (Zen limits, vet, strict style)
make vet

# Run the complete verification suite:
# - Unit tests in both debug and -o:speed
# - Compile-fail capacity contracts
# - Durability gate invariant assertions
# - 9 chaos simulations across 1, 3, and 5 nodes (9,000 fault steps)
# - Multi-master search example execution
# - Benchmark smoke runs
# - CLI error propagation
make check

# Run seeded chaos simulator
make sim

# Compile documentation book and SOD records to PDF
make docs
```

---

## License

SQLodin is released under the [MIT License](LICENSE).
