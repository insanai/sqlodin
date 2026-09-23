#import "theme.typ": *

#{
  set page(header: none, footer: none, numbering: none,
    margin: (x: 24mm, top: 22mm, bottom: 22mm),
    background: rect(width: 100%, height: 100%, fill: rgb("f7f8f5")))
  set par(justify: false)
  text(font: "New Computer Modern Sans", size: 8pt, tracking: 1.3pt, fill: blue)[
    THE SQLODIN BOOK / SEPTEMBER 2026]
  v(20mm)
  text(size: 48pt, weight: "bold", fill: ink)[SQLodin]
  v(5mm)
  text(font: "New Computer Modern Sans", size: 19pt, fill: ink)[
    Architecture, durability
    and performance]
  v(6mm)
  box(width: 84%)[
    #text(size: 12pt, fill: gray)[
      Multi-master SQLite in Odin, built on the complete paxos-odin library.
      A guide to the implementation, its guarantees, and the work ahead.]
  ]
  v(15mm)
  line(length: 100%, stroke: 0.6pt + rule)
  v(7mm)
  text(font: "New Computer Modern Sans", size: 8pt, tracking: 1pt, fill: blue)[
    THREE OWNERS. ONE ORDERED HISTORY.]
  v(7mm)
  grid(columns: (1fr, 1fr, 1fr), gutter: 9pt,
    ..(1, 2, 3).map(n => block(width: 100%, inset: 10pt,
      fill: blue_light, stroke: 0.7pt + rule)[
      #text(font: "New Computer Modern Sans", size: 10pt, weight: "bold")[Voter #n]
      #linebreak()
      #text(size: 9pt, fill: gray)[Propose / persist / apply]
    ]))
  v(5mm)
  align(center, text(size: 18pt, fill: blue)[↓])
  v(3mm)
  grid(columns: (1fr, 1fr, 1fr, 1fr, 1fr, 1fr), gutter: 4pt,
    ..range(1, 7).map(s => block(width: 100%, inset: 8pt,
      fill: if calc.rem(s, 3) == 1 { rgb("d8e9ec") } else { rgb("e8eeed") },
      align(center, text(font: "New Computer Modern Sans", size: 9pt)[Slot #s]))))
  v(5mm)
  text(size: 10pt, fill: gray)[Quorum choice → durable contiguous application → acknowledgement]
  v(1fr)
  line(length: 100%, stroke: 0.6pt + rule)
  v(6mm)
  text(size: 12pt, weight: "bold")[Vikrant Rathore]
  linebreak()
  text(size: 10.5pt, fill: gray)[With assistance from Ronak Rathore]
  v(4mm)
  text(font: "New Computer Modern Sans", size: 8pt, fill: gray)[
    IMPLEMENTATION GUIDE AND ENGINEERING RECORD]
  pagebreak()
}

#heading(level: 1, numbering: none, outlined: false)[About this book]

SQLodin admits proposals at every voter and applies one ordered stream of logical mutations to
SQLite. The complete, pinned paxos-odin library owns consensus. SQLodin owns the mutation format,
SQLite application and a fixed-membership durable host. sqlite-vec and FTS5 supply embedded search.

This book is written by *Vikrant Rathore, with assistance from Ronak Rathore*. It describes the
repository as reviewed on 23 September 2026. The title is an engineering objective; the evidence
and limitations in each chapter define what the current implementation can support.

#callout(title: "Current maturity", kind: "warning")[
  SQLodin has embedded and standalone mTLS SQL interfaces. It is not production-ready.
  Format 4 adds bounded serializable ORM transactions to durable outcomes, group commit and
  fresh ordered read barriers. Complete SQL determinism, certified snapshots and service
  qualification remain open. Historical reports retain their measured source versions.
]

== Choose a reading route

#table(columns: (1fr, 2.2fr),
  table.header([*Your task*], [*Start here*]),
  [Build and experiment], [Start with “Build and inspect.” The example runs three in-process
    nodes; the durable verification uses separate disk files.],
  [Understand the design], [Read foundations, rotating ownership and host obligations, then
    follow the SQLite application and read-consistency chapters.],
  [Evaluate performance], [Read the durable Linux workloads and storage-cost diagnosis first.
    The historical memory study has a different measurement boundary.],
  [Plan production work], [Read the readiness review and the “Production SQL and Durable
    Throughput” SOD 0004. Its acceptance targets are provisional, not benchmark results.],
)

== How to interpret the evidence

*Implemented* describes code in this repository. *Measured* describes a named JSON report and its
source snapshot. *Proposed* describes work in a draft SOD. Passing a process-crash test is evidence
for that scenario; it does not prove physical power-loss recovery or arbitrary distributed histories.

The book imports benchmark JSON directly so published tables remain tied to recorded samples.
Earlier unverified throughput and fixed WAN-latency claims have been withdrawn. The retained memory
study is historical, while the durable comparison and cost profile describe later implementations.

Source: `docs/book.typ`. Build: `make docs`. SOD sources live under `docs/sod/records`;
`docs/production-readiness.md` records the reproduced blockers. A SOD's lifecycle state records a
design decision, not a production certification.
