#import "theme.typ": blue, gray, rule, callout

#align(center)[
  #v(3em)
  #text(size: 28pt, weight: "bold", fill: blue)[SQLodin]
  #v(0.8em)
  #text(size: 15pt, weight: "medium", fill: rgb("334155"))[
    Distributed Multi-Master SQLite via Rotating Paxos Consensus
  ]
  #v(0.5em)
  #text(size: 11pt, fill: gray)[
    Zero 42ms Latency Penalty #h(0.5em) #sym.bullet #h(0.5em)
    Deterministic Logical Mutations #h(0.5em) #sym.bullet #h(0.5em)
    sqlite-vec & FTS5
  ]
  #v(2.5em)
  #line(length: 60%, stroke: 0.8pt + rule)
  #v(2em)

  #text(size: 10pt, weight: "bold")[Vikrant Rathore] \
  #text(size: 9pt, fill: gray)[With technical assistance from Ronak Rathore] \
  #text(size: 8.5pt, fill: gray)[InsanAI Research & Engineering #h(0.4em) #sym.bullet #h(0.4em) September 2026]
]

#v(4em)

== Abstract

*SQLodin* is an idiomatic Odin implementation of a distributed, multi-master SQLite database.
Traditional replicated SQLite architectures—exemplified by Zaxonlite—replicate physical SQLite
Write-Ahead Log (WAL) frame pages. Because concurrent physical page writes to SQLite B-trees cause
irrecoverable file corruption, single-writer architectures are forced to funnel all write traffic
through a designated leader node. In distributed deployments across geographic regions, this
forwarding hop imposes an unavoidable *~42 millisecond latency penalty* on every write initiated
at a non-leader replica.

SQLodin eliminates this penalty entirely. By redesigning the replication layer around
*rotating slot ownership* (a log partitioning scheme inspired by Mencius) and *deterministic
logical mutations*, every node in the cluster acts as a master capable of committing writes in
*1 RTT* directly to peer quorums without forwarding. To ensure conflict-free primary keys across
masters without distributed locks, SQLodin integrates 64-bit Snowflake identifiers. Furthermore,
SQLodin compiles and links `sqlite-vec` natively alongside FTS5, providing low-latency vector KNN
similarity search and full-text querying across a replicated relational engine.

#v(2em)

== The Zen of Odin for InsanAI Systems

SQLodin is engineered under the strict mechanical constraints of the *Zen of Odin for InsanAI*:

+ *Simplicity over Complexity:* Explicit data layout, pure deterministic state transitions, zero hidden control flow.
+ *No Unbounded Work:* Compile-time sizing, statically bounded buffers, zero heap allocations during consensus execution.
+ *Total Verification:* Every invariant backed by formal contract assertions, chaos simulations, and property checks.
+ *Clear Failure Modes:* Elm-style `-- BANNER --` diagnostics that explain *what* went wrong, *why*, and provide a concrete *Hint:*.
+ *Architectural Limits:* Every source file is bounded to 1,408 lines, line widths capped at 99 columns (108 hard), and procedure logic limited to 70 statements.
