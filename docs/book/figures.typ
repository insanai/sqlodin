// Visual Figures and Diagrams for SQLodin Book
#import "theme.typ": blue, blue_light, green, green_light, amber, amber_light, red, gray, rule

#let diagram_box(title: none, content) = {
  align(center)[
    #block(
      width: 95%,
      stroke: 0.5pt + rule,
      radius: 4pt,
      fill: rgb("fafafa"),
      inset: 12pt,
      [
        #if title != none [
          #text(weight: "bold", size: 9pt, fill: gray)[#title]
          #v(0.6em)
        ]
        #content
      ]
    )
  ]
}

#let multi_master_topology() = diagram_box(
  title: "Multi-Master Rotating Slot Partitioning vs Single-Leader Forwarding",
  [
    #grid(
      columns: (1fr, 1fr),
      gutter: 14pt,
      [
        #block(
          width: 100%,
          stroke: 0.8pt + red,
          fill: rgb("fff5f5"),
          inset: 8pt,
          radius: 3pt,
          [
            #text(weight: "bold", fill: red, size: 9pt)[Single Leader (Zaxonlite)]
            #v(4pt)
            #text(size: 8pt)[
              - Client writes to Node 2
              - *WAN Forward Hop (+21ms)* to Leader (Node 1)
              - Node 1 proposes and broadcasts
              - *WAN Ack Hop (+21ms)* back to Node 2
              - *Total Penalty: ~42ms per write!*
            ]
          ]
        )
      ],
      [
        #block(
          width: 100%,
          stroke: 0.8pt + green,
          fill: rgb("f0fdf4"),
          inset: 8pt,
          radius: 3pt,
          [
            #text(weight: "bold", fill: green, size: 9pt)[SQLodin Multi-Master]
            #v(4pt)
            #text(size: 8pt)[
              - Client writes to Node 2
              - Node 2 owns Slot 2 ($2 mod 3 = 2$)
              - *1-RTT Direct Accept* to peers in Round 0
              - Quorum acks: Committed immediately!
              - *Total Penalty: 0.00ms (Local Fast-Path)*
            ]
          ]
        )
      ]
    )
  ]
)

#let rotating_slot_timeline() = diagram_box(
  title: "Rotating Slot Log Partitioning & Deterministic Application",
  [
    #table(
      columns: (60pt, 80pt, 80pt, 80pt, 100pt),
      align: center + horizon,
      table.header([*Slot*], [*Slot Owner*], [*Ballot*], [*Mutation*], [*State Machine*]),
      [1], [Node 1], [`(0, 0, 1)`], [INSERT doc 1], [Applied to WAL],
      [2], [Node 2], [`(0, 0, 2)`], [INSERT vec 1], [Applied to WAL],
      [3], [Node 3], [`(0, 0, 3)`], [UPDATE doc 1], [Applied to WAL],
      [4], [Node 1], [`(0, 0, 1)`], [SKIP (Idle)], [Advances Watermark],
      [5], [Node 2], [`(0, 0, 2)`], [DELETE doc 1], [Idempotent Delete],
    )
  ]
)

#let effect_pipeline_figure() = diagram_box(
  title: "Zero-Heap Pure Effect Machine Transition",
  [
    #grid(
      columns: (1fr, 20pt, 1fr, 20pt, 1fr),
      align: center + horizon,
      [
        #block(fill: blue_light, stroke: 0.8pt + blue, inset: 6pt, radius: 3pt)[
          *Transition Input*\
          `Envelope(V)` / `Propose`
        ]
      ],
      [#text(fill: blue, size: 14pt)[#sym.arrow]],
      [
        #block(fill: rgb("f8fafc"), stroke: 1.2pt + blue, inset: 8pt, radius: 4pt)[
          *SQLodin Consensus*\
          Pure State Machine\
          (Zero Heap Allocations)
        ]
      ],
      [#text(fill: blue, size: 14pt)[#sym.arrow]],
      [
        #block(fill: green_light, stroke: 0.8pt + green, inset: 6pt, radius: 3pt)[
          *Effects(V)*\
          `writes` (Durable WAL)\
          `messages` (UDP/TCP)\
          `committed` (SQLite)
        ]
      ]
    )
  ]
)
