// SQLodin Discussions (SOD): portable type, explicit lifecycle, stable metadata.
// Inspired by RFC specifications and ensodiscussions (EDS).
// SOD stands for SQLODIN Discussions — records for discussion on improvement,
// architecture, consensus, durability, and enhancements of SQLodin.

#import "theme.typ": *
#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge
#import "@preview/cetz:0.5.2"

#let sod-placeholder-number = "XXXXX"

// ---------------------------------------------------------------------------
// Standard SQLodin Discussion color palette
// ---------------------------------------------------------------------------
#let sod-palette = (
  teal: rgb("#166777"),
  teal-light: rgb("#e6f4f6"),
  teal-dark: rgb("#0d4b57"),
  navy: rgb("#182e3b"),
  slate: rgb("#64748b"),
  slate-light: rgb("#f8fafc"),
  border: rgb("#cbd5e1"),
  emerald: rgb("#059669"),
  emerald-light: rgb("#ecfdf5"),
  amber: rgb("#d97706"),
  amber-light: rgb("#fef3c7"),
  violet: rgb("#7c3aed"),
  violet-light: rgb("#f5f3ff"),
  rose: rgb("#e11d48"),
  rose-light: rgb("#fff1f2"),
  ink: rgb("#0f172a"),
)

// ---------------------------------------------------------------------------
// State badge colors matching EDS specification lifecycle
// ---------------------------------------------------------------------------
#let sod-state-fill(state) = {
  if state == "published" {
    rgb("#dbeafe") // soft blue
  } else if state == "discussion" {
    rgb("#dcfce7") // soft green
  } else if state == "committed" {
    rgb("#ede9fe") // soft purple
  } else if state == "abandoned" {
    rgb("#e5e7eb") // soft neutral gray
  } else {
    rgb("#fef3c7") // soft amber (prediscussion / draft)
  }
}

#let sod-state-stroke(state) = {
  if state == "published" {
    rgb("#93c5fd")
  } else if state == "discussion" {
    rgb("#86efac")
  } else if state == "committed" {
    rgb("#c4b5fd")
  } else if state == "abandoned" {
    rgb("#d1d5db")
  } else {
    rgb("#fde047")
  }
}

#let sod-state-text(state) = {
  if state == "published" {
    rgb("#1e40af")
  } else if state == "discussion" {
    rgb("#166534")
  } else if state == "committed" {
    rgb("#5b21b6")
  } else if state == "abandoned" {
    rgb("#374151")
  } else {
    rgb("#854d0e")
  }
}

#let sod-chip(label, fill, stroke: auto, text-color: auto) = {
  let s = if stroke == auto { none } else { stroke }
  let c = if text-color == auto { primary-color } else { text-color }
  box(
    inset: (x: 0.55em, y: 0.28em),
    radius: 999pt,
    fill: fill,
    stroke: s,
  )[
    #text(font: "New Computer Modern Sans", size: 8pt, weight: "bold", fill: c)[#label]
  ]
}

#let sod-format-title(number, title) = {
  if number == sod-placeholder-number {
    [SOD #sod-placeholder-number: #title]
  } else {
    [SOD #number: #title]
  }
}

#let sod-label(label) = text(
  font: "New Computer Modern Sans",
  size: 8.2pt,
  weight: "bold",
  tracking: 0.05em,
  fill: rgb("#475569"),
)[#upper(label)]

#let sod-value(body) = text(
  size: 9.8pt,
  fill: rgb("#0f172a"),
)[#body]

#let authors-block(authors) = {
  if authors.len() == 0 {
    [SQLodin Contributors]
  } else {
    authors.join("\n")
  }
}

// ---------------------------------------------------------------------------
// Callout & Diagram Container Helpers
// ---------------------------------------------------------------------------

#let invariant-box(title: none, body) = block(
  width: 100%,
  breakable: false,
  inset: (x: 12pt, top: 9pt, bottom: 9pt),
  radius: (right: 4pt),
  fill: rgb("#f0f8fa"),
  stroke: (left: 3pt + rgb("#166777"), rest: 0.5pt + rgb("#d1e6ea")),
  below: 1.2em,
)[
  #text(font: "New Computer Modern Sans", size: 8.5pt, weight: "bold", fill: rgb("#166777"))[
    INVARIANT #if title != none and title != "" [— #title]
  ] \
  #v(2pt)
  #text(size: 9.8pt)[#body]
]

#let decision-box(title: none, body) = block(
  width: 100%,
  breakable: false,
  inset: (x: 12pt, top: 9pt, bottom: 9pt),
  radius: (right: 4pt),
  fill: rgb("#ecfdf5"),
  stroke: (left: 3pt + rgb("#059669"), rest: 0.5pt + rgb("#bbf7d0")),
  below: 1.2em,
)[
  #text(font: "New Computer Modern Sans", size: 8.5pt, weight: "bold", fill: rgb("#047857"))[
    DECISION #if title != none and title != "" [— #title]
  ] \
  #v(2pt)
  #text(size: 9.8pt)[#body]
]

#let warning-box(title: none, body) = block(
  width: 100%,
  breakable: false,
  inset: (x: 12pt, top: 9pt, bottom: 9pt),
  radius: (right: 4pt),
  fill: rgb("#fff1f2"),
  stroke: (left: 3pt + rgb("#e11d48"), rest: 0.5pt + rgb("#fecdd3")),
  below: 1.2em,
)[
  #text(font: "New Computer Modern Sans", size: 8.5pt, weight: "bold", fill: rgb("#be123c"))[
    BOUNDARY #if title != none and title != "" [— #title]
  ] \
  #v(2pt)
  #text(size: 9.8pt)[#body]
]

#let proof-box(title: none, body) = block(
  width: 100%,
  breakable: false,
  inset: (x: 12pt, top: 9pt, bottom: 9pt),
  radius: (right: 4pt),
  fill: rgb("#f5f3ff"),
  stroke: (left: 3pt + rgb("#7c3aed"), rest: 0.5pt + rgb("#ddd6fe")),
  below: 1.2em,
)[
  #text(font: "New Computer Modern Sans", size: 8.5pt, weight: "bold", fill: rgb("#6d28d9"))[
    PROOF #if title != none and title != "" [— #title]
  ] \
  #v(2pt)
  #text(size: 9.8pt)[#body]
]

#let diagram-content(body) = context {
  if target() == "html" { html.frame(block(width: 165mm, body)) } else { body }
}

#let diagram-card(caption: none, body) = diagram-content(align(center)[
  #block(
    width: 100%,
    breakable: false,
    inset: 12pt,
    radius: 4pt,
    fill: luma(99.5%),
    stroke: 0.65pt + rgb("#cbd5e1"),
    below: 1.4em,
  )[
    #align(center)[#body]
    #if caption != none [
      #v(6pt)
      #line(length: 100%, stroke: 0.4pt + rgb("#e2e8f0"))
      #v(4pt)
      #text(font: "New Computer Modern Sans", size: 8.5pt, style: "italic", fill: rgb("#64748b"))[
        #caption
      ]
    ]
  ]
])

#let zen-box(body) = block(
  width: 100%,
  breakable: false,
  inset: (x: 14pt, top: 11pt, bottom: 11pt),
  radius: 4pt,
  fill: rgb("#f8fafc"),
  stroke: 0.75pt + rgb("#cbd5e1"),
  below: 1.2em,
)[
  #set text(style: "italic")
  #body
]

// ---------------------------------------------------------------------------
// Document Template: RFC Header, Metadata Card, Table of Contents, Layout
// ---------------------------------------------------------------------------

#let sod-document(
  number,
  title,
  body,
  authors: (project-authorship,),
  state: "prediscussion",
  created: "YYYY-MM-DD",
  discussion: "",
  labels: (),
  category: "Engineering Discussion",
  status: "Draft",
  last-updated: "None",
) = [
  #set document(title: [SOD #number: #title], author: authors)
  #set page(
    paper: "a4",
    margin: (x: 22mm, top: 22mm, bottom: 22mm),
    numbering: "1",
    header: context {
      set text(font: "New Computer Modern Sans", size: 8pt, fill: muted-color)
      grid(
        columns: (1fr, auto),
        [SQLodin Discussions (SOD)],
        [SOD #if number == sod-placeholder-number { [#sod-placeholder-number] } else { [#number] }],
      )
      v(-2pt)
      line(length: 100%, stroke: 0.5pt + border-color)
    },
    footer: context {
      set text(font: "New Computer Modern Sans", size: 8pt, fill: muted-color)
      line(length: 100%, stroke: 0.4pt + rgb("#e2e8f0"))
      v(1pt)
      grid(
        columns: (1fr, auto),
        [SQLODIN WORKING GROUP / DESIGN & IMPROVEMENT RECORD],
        counter(page).display(),
      )
    },
  )

  #show: typography
  #set heading(numbering: "1.1")
  #counter(heading).update(0)

  #context if target() == "html" [
    #html.elem("header", [
      #html.elem("h1", [SOD #number: #title])
      #par[*Status:* #status / *Created:* #created / *Updated:* #last-updated]
      #par[#authors-block(authors)]
      #par[#category / #discussion]
    ])
  ] else [
  // RFC-style Header Card inspired by ensodiscussions (EDS)
  #block(
    width: 100%,
    breakable: false,
    inset: (x: 1.15em, y: 1.05em),
    radius: 4pt,
    stroke: 0.75pt + rgb("#cbd5e1"),
    fill: luma(99.2%),
  )[
    #set par(justify: false)
    #grid(
      columns: (1fr, auto),
      column-gutter: 1.4em,
      align: (left, top),
      [
        #text(12.4pt, weight: "bold", fill: primary-color)[SQLodin Working Group]
        #linebreak()
        #text(9pt, fill: rgb("#64748b"))[Request for Discussion and Implementation Record]
      ],
      [
        #align(right)[
          #text(13.5pt, weight: "bold", fill: accent-color)[SOD #if number == sod-placeholder-number { [#sod-placeholder-number] } else { [#number] }]
          #linebreak()
          #text(9pt, weight: "semibold", fill: rgb("#64748b"))[#category]
        ]
      ],
    )

    #v(0.85em)
    #text(21pt, weight: "bold", fill: primary-color)[#title]

    #v(0.55em)
    #line(length: 100%, stroke: 0.7pt + rgb("#e2e8f0"))

    #v(0.75em)
    #grid(
      columns: (1fr, 1.25fr),
      column-gutter: 1.8em,
      row-gutter: 0.5em,
      align: (left, top),
      [#sod-label[STATE]],
      [#sod-label[INTENDED STATUS]],
      [#sod-chip(upper(state), sod-state-fill(state), stroke: 0.5pt + sod-state-stroke(state), text-color: sod-state-text(state))],
      [#sod-value[#status]],
      [#sod-label[CREATED]],
      [#sod-label[AUTHORS]],
      [#sod-value[#created]],
      [#block(width: 100%)[#sod-value[#authors-block(authors)]]],
      [#sod-label[LAST UPDATED]],
      [#sod-label[DISCUSSION FORUM]],
      [#sod-value[#last-updated]],
      [#block(width: 100%)[#sod-value[#discussion]]],
    )

    #if labels.len() > 0 [
      #v(0.6em)
      #sod-label[TOPICS & LABELS]
      #linebreak()
      #v(2pt)
      #box[
        #for l in labels [
          #box(
            inset: (x: 5pt, y: 2.5pt),
            radius: 3pt,
            fill: rgb("#f1f5f9"),
            stroke: 0.4pt + rgb("#cbd5e1"),
          )[#text(font: "New Computer Modern Sans", size: 8pt, fill: rgb("#334155"))[#l]]
          #h(3pt)
        ]
      ]
    ]
  ]

  ]

  #v(0.8em)

  // Status of This Memo block
  #block(
    width: 100%,
    breakable: false,
    inset: 0.9em,
    radius: 4pt,
    stroke: 0.7pt + rgb("#94a3b8"),
    fill: luma(98%),
  )[
    #text(font: "New Computer Modern Sans", weight: "bold", size: 9.5pt, fill: primary-color)[Status of This Record]
    #v(3pt)
    #text(size: 9.2pt)[
      This document is a *SQLodin Discussion (SOD)* record authored in Typst and tracked in git. It follows an RFC-style specification structure so that architectural scope, rationale, trade-offs, proof obligations, and operational boundaries remain explicit. Documents using the placeholder number #text(font: "New Computer Modern Mono", size: 9pt)[#sod-placeholder-number] are provisional drafts. Numbered SOD documents are permanent engineering records for discussion on improvement, architecture, and enhancements of SQLodin.
    ]
  ]

  #v(0.6em)
  #outline(indent: 1.4em)
  #v(1em)

  #body
]

// ---------------------------------------------------------------------------
// Index Page Generator for Master Catalog and Bundle
// ---------------------------------------------------------------------------

#let sod-index-page(sod-documents) = configure-document(
  title: "SQLodin Discussions",
  [
    #block(
      width: 100%,
      breakable: false,
      inset: (x: 1.2em, y: 1.1em),
      radius: 4pt,
      stroke: 0.8pt + rgb("#cbd5e1"),
      fill: rgb("#f8fafc"),
    )[
      #grid(
        columns: (1fr, auto),
        align: (left, horizon),
        [
          #text(font: "New Computer Modern Sans", size: 8.5pt, tracking: 0.08em, weight: "bold", fill: accent-color)[
            SQLODIN WORKING GROUP
          ]
          #linebreak()
          #text(font: "New Computer Modern Sans", size: 24pt, weight: "bold", fill: primary-color)[
            SQLodin Discussions (SOD)
          ]
        ],
        [
          #box(
            inset: (x: 8pt, y: 4pt),
            radius: 4pt,
            fill: rgb("#e6f4f6"),
            stroke: 0.6pt + accent-color,
          )[
            #text(font: "New Computer Modern Sans", size: 8.5pt, weight: "bold", fill: accent-color)[
              RFC SERIES
            ]
          ]
        ],
      )

      #v(0.4em)
      #line(length: 100%, stroke: 0.7pt + rgb("#e2e8f0"))
      #v(0.5em)

      #text(size: 10pt, fill: rgb("#334155"))[
        *SOD* stands for *SQLODIN Discussions* — versioned engineering records for discussion on improvement, architecture, consensus derivations, durable storage design, and operational enhancements of SQLodin.
      ]

      #v(0.3em)
      #text(size: 8.8pt, fill: muted-color)[
        Modeled after the Paxos Odin Discussions (POD) and inspired by the ensodiscussions (EDS) RFC architecture.
      ]
    ]

    #v(1em)

    #text(font: "New Computer Modern Sans", size: 13pt, weight: "bold", fill: primary-color)[
      Active Discussion & Implementation Records
    ]
    #v(0.3em)

    #for doc in sod-documents [
      #block(
        width: 100%,
        breakable: false,
        inset: 10pt,
        radius: 3pt,
        stroke: 0.6pt + border-color,
        fill: luma(99.6%),
        below: 3mm,
      )[
        #grid(
          columns: (1fr, auto),
          gutter: 10pt,
          align: (left, top),
          [
            #text(font: "New Computer Modern Sans", size: 12.5pt, weight: "bold", fill: accent-color)[
              SOD #doc.number: #doc.title
            ]
          ],
          [
            #sod-chip(
              upper(doc.state),
              sod-state-fill(doc.state),
              stroke: 0.5pt + sod-state-stroke(doc.state),
              text-color: sod-state-text(doc.state),
            )
          ],
        )
        #v(3pt)
        #text(size: 9.5pt)[#doc.summary]
        #v(4pt)
        #line(length: 100%, stroke: 0.35pt + rgb("#f1f5f9"))
        #v(2pt)
        #grid(
          columns: (1fr, auto),
          [#text(size: 8.2pt, fill: muted-color)[Category: *#doc.category*]],
          [#text(size: 8.2pt, fill: muted-color)[Updated: #doc.updated]],
        )
      ]
    ]

    #v(0.6em)
    #block(
      width: 100%,
      breakable: false,
      inset: 10pt,
      radius: 3pt,
      stroke: 0.6pt + rgb("#e2e8f0"),
      fill: rgb("#fffbeb"),
    )[
      #grid(
        columns: (1fr, auto),
        align: (left, top),
        [
          #text(font: "New Computer Modern Sans", size: 11.5pt, weight: "bold", fill: rgb("#92400e"))[
            Pre-Discussion Proposals & Working Drafts
          ]
        ],
        [
          #sod-chip(
            "PREDISCUSSION",
            sod-state-fill("prediscussion"),
            stroke: 0.5pt + sod-state-stroke("prediscussion"),
            text-color: sod-state-text("prediscussion"),
          )
        ],
      )
      #v(4pt)
      #text(size: 9.5pt, fill: rgb("#1e293b"))[
        *SOD XXXXX: Pinned Upstream Paxos and SQLite Application Correctness* \
        #text(size: 8.8pt, fill: rgb("#475569"))[
          Pre-discussion draft proposing the integration boundary for the pinned upstream Paxos state machine, atomic SQLite application watermarks, cached prepared statements, and memory budgets.
        ]
      ]
    ]
  ],
)
