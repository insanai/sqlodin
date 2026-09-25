#import "theme.typ": *
#import "figures.typ": slots

#{
  set page(header: none, footer: none, numbering: none,
    margin: (x: 24mm, top: 23mm, bottom: 22mm),
    background: rect(width: 100%, height: 100%, fill: rgb("f7f8f5")))
  set par(justify: false)
  text(font: "New Computer Modern Sans", size: 9pt, tracking: 1pt, fill: blue)[THE SQLODIN BOOK]
  v(24mm)
  text(size: 48pt, weight: "bold", fill: ink)[SQLodin]
  v(5mm)
  text(font: "New Computer Modern Sans", size: 20pt)[Use, design and evidence]
  v(8mm)
  box(width: 85%)[
    #text(size: 13pt, fill: gray)[A replicated SQLite database in Odin.
    Writes can enter at any voter. Every voter applies the same ordered history.]
  ]
  v(22mm)
  slots()
  v(5mm)
  text(size: 11pt, fill: gray)[Three owners. One application order.]
  v(1fr)
  line(length: 100%, stroke: 0.6pt + rule)
  v(7mm)
  text(size: 13pt, weight: "bold")[Vikrant Rathore]
  linebreak()
  text(size: 11pt, fill: gray)[With assistance from Ronak Rathore]
  v(5mm)
  text(font: "New Computer Modern Sans", size: 9pt, fill: gray)[25 September 2026]
  pagebreak()
}

#heading(level: 1, numbering: none, outlined: false)[How to use this book]

Read @start to build SQLodin and run your first query. Read @clients and @search
for application code. The design begins at @history. The proof chapter, @proofs,
explains which claims follow from induction, which are checked within finite models,
and which depend on the implementation and its environment.

#table(columns: (1.15fr, 1.8fr),
  table.header([If you need to…], [Start here]),
  [Run SQL], [@start; command lookup in @reference],
  [Write a Python application], [@clients; search in @search],
  [Understand multi-master writes], [@history and @consensus],
  [Reason about crashes or retries], [@storage, @transactions and @recovery],
  [Inspect the mathematics], [@proofs and its links to executable specifications],
  [Choose a workload or size a deployment], [@runtime and @benchmarks],
)

The book describes the qualified fixed three-voter implementation. It uses the
complete pinned paxos-odin library, SQLite 3.51.3, sqlite-vec 0.1.9 and OpenSSL 3.5.8.
The native service and Python package have separate version numbers. Store format 5
and SQL policy 9 identify the current storage and SQL contracts.

A release decision has a scope. The Linux checks use three instances and durable
local storage. They do not establish independent physical failure domains or
physical power-loss behavior. Performance targets remain unmet. Large-database
recovery time is not guaranteed. @benchmarks gives the measurements and their limits.

The #link("../releases/2026-09-25.typ")[release record] identifies the tested binary
and accepted scope. The #link("../index.typ")[documentation index] leads to operating
guides, design decisions and historical records. Historical notes describe earlier
states of the code; they do not override the contracts explained here.
