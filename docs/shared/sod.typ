// SQLodin Discussions (SOD) Specification Frame & Helper Library
// Modeled on the Paxos Odin Discussions (POD) from paxos-odin and ZDS from zenfmt.

#import "theme.typ": primary-color, secondary-color, accent-color, muted-color, bg-light, border-color

#let sod-placeholder-number = "XXXXX"

#let sod-state-fill(state) = {
  if state == "published" {
    rgb("dbeafe") // blue
  } else if state == "discussion" {
    rgb("dcfce7") // green
  } else if state == "committed" {
    rgb("ede9fe") // purple
  } else if state == "abandoned" {
    rgb("e5e7eb") // gray
  } else {
    rgb("fef3c7") // yellow
  }
}

#let sod-chip(label, fill) = box(
  inset: (x: 0.5em, y: 0.25em),
  radius: 999pt,
  fill: fill,
  stroke: none,
)[
  #text(8.5pt, weight: "bold", fill: rgb("1e293b"))[#label]
]

#let sod-title(number, title) = {
  if number == sod-placeholder-number {
    [SOD #sod-placeholder-number: #title]
  } else {
    [SOD #number: #title]
  }
}

#let sod-label(label) = text(8.5pt, weight: "bold", fill: rgb("64748b"))[#upper(label)]
#let sod-value(body) = text(9.5pt, fill: rgb("0f172a"))[#body]

#let sod-document(
  number,
  title,
  body,
  authors: (),
  state: "discussion",
  created: "YYYY-MM-DD",
  discussion: "",
  labels: (),
  category: "Engineering Discussion",
  status: "Draft",
  last-updated: "None",
) = {
  set document(title: [SOD #number: #title], author: authors)
  set page(
    paper: "a4",
    margin: (x: 2cm, top: 2.5cm, bottom: 2.5cm),
    numbering: "1",
    header: context {
      if counter(page).get().first() > 1 {
        text(9pt, fill: muted-color, font: ("Liberation Sans", "DejaVu Sans", "Helvetica Neue", "Arial"))[
          SOD #number: #title
          #h(1fr)
          SQLodin Discussions
        ]
      }
    },
    footer: context {
      text(9pt, fill: muted-color, font: ("Liberation Sans", "DejaVu Sans", "Helvetica Neue", "Arial"))[
        #h(1fr)
        Page #counter(page).display()
      ]
    },
  )

  set text(
    font: ("Liberation Sans", "DejaVu Sans", "Helvetica Neue", "Arial"),
    size: 10.5pt,
    fill: primary-color,
    lang: "en",
    hyphenate: true,
    costs: (orphan: 100%, widow: 100%),
  )

  set smartquote(enabled: false)

  set par(
    justify: true,
    linebreaks: "optimized",
    leading: 0.72em,
  )

  show raw: set text(hyphenate: false)
  show table: set par(justify: false)
  show heading: set par(justify: false)

  // Document Header
  v(0.5cm)
  grid(
    columns: (1fr, auto),
    gutter: 1cm,
    [
      #text(20pt, weight: "bold", fill: rgb("0f172a"))[#sod-title(number, title)]
    ],
    [
      #sod-chip(upper(state), sod-state-fill(state))
    ]
  )
  v(0.5cm)

  let authors-str = if type(authors) == array { authors.join(", ") } else { str(authors) }
  let labels-str = if type(labels) == array { labels.join(", ") } else { str(labels) }

  // Metadata Box
  block(
    width: 100%,
    fill: bg-light,
    stroke: 0.5pt + border-color,
    radius: 6pt,
    inset: 12pt,
    [
      #grid(
        columns: (1fr, 1fr),
        row-gutter: 10pt,
        column-gutter: 20pt,
        [#sod-label("Category")\ #sod-value(category)],
        [#sod-label("Status")\ #sod-value(status)],
        [#sod-label("Authors")\ #sod-value(authors-str)],
        [#sod-label("Created")\ #sod-value(created)],
        [#sod-label("Last Updated")\ #sod-value(last-updated)],
        [#sod-label("Labels")\ #sod-value(labels-str)],
      )
    ]
  )

  v(0.8cm)
  line(length: 100%, stroke: 0.5pt + border-color)
  v(0.5cm)

  body
}

#let sod-index-page(sod-documents) = {
  set document(title: "SQLodin Discussions Index", author: "SQLodin Contributors")
  set page(
    paper: "a4",
    margin: (x: 2cm, top: 2.5cm, bottom: 2.5cm),
    numbering: "1",
    header: text(9pt, fill: muted-color, font: ("Liberation Sans", "DejaVu Sans", "Helvetica Neue", "Arial"))[SQLodin Discussions (SOD) Index],
    footer: context {
      text(9pt, fill: muted-color, font: ("Liberation Sans", "DejaVu Sans", "Helvetica Neue", "Arial"))[#h(1fr) Page #counter(page).display()]
    },
  )
  set text(font: ("Liberation Sans", "DejaVu Sans", "Helvetica Neue", "Arial"), size: 10pt)

  v(0.5cm)
  text(22pt, weight: "bold", fill: rgb("0f172a"))[SQLodin Discussions (SOD)]
  v(0.2cm)
  text(11pt, fill: muted-color)[Formal design proposals, multi-master consensus derivations, and operational RFCs for SQLodin.]
  v(0.8cm)

  table(
    columns: (auto, auto, 2fr, 3fr),
    stroke: 0.5pt + border-color,
    fill: (col, row) => if row == 0 { rgb("f1f5f9") } else { none },
    inset: 8pt,
    align: (col, row) => (
      if col == 0 { center }
      else if col == 1 { center }
      else { left }
    ),
    [*SOD*], [*State*], [*Title*], [*Summary*],
    ..sod-documents.map(doc => (
      [#strong(doc.number)],
      sod-chip(upper(doc.state), sod-state-fill(doc.state)),
      [#strong(doc.title)\ #text(8pt, fill: muted-color)[#doc.category]],
      text(9pt)[#doc.summary],
    )).flatten()
  )
}
