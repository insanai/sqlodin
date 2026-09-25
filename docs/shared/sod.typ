// SQLodin discussion records: portable type, explicit lifecycle, stable metadata.
#import "theme.typ": *
#let sod-placeholder-number = "XXXXX"
#let sod-state-fill(state) = if state == "committed" { rgb("e7f0eb") }
  else if state == "abandoned" { rgb("edf0f1") } else { rgb("faf1df") }
#let sod-chip(label, fill) = box(inset: (x: 6pt, y: 3pt), fill: fill)[
  #text(font: "New Computer Modern Sans", size: 8pt, weight: "bold")[#label]
]
#let sod-title(number, title) = [SOD #number: #title]
#let sod-label(label) = text(font: "New Computer Modern Sans", size: 8pt,
  tracking: 0.4pt, weight: "bold", fill: muted-color)[#upper(label)]
#let sod-value(body) = text(size: 10pt, fill: primary-color)[#body]

#let sod-document(number, title, body, authors: (project-authorship,),
  state: "prediscussion", created: "YYYY-MM-DD", discussion: "", labels: (),
  category: "Engineering Discussion", status: "Draft", last-updated: "None") = {
  set document(title: [SOD #number: #title], author: authors)
  set page(paper: "a4", margin: (x: 23mm, top: 23mm, bottom: 23mm), numbering: "1",
    header: context {
      set text(font: "New Computer Modern Sans", size: 8pt, fill: muted-color)
      grid(columns: (1fr, auto), [SQLodin Discussions], [SOD #number])
      line(length: 100%, stroke: 0.5pt + border-color)
    }, footer: context {
      set text(font: "New Computer Modern Sans", size: 8pt, fill: muted-color)
      grid(columns: (1fr, auto), [DESIGN & IMPLEMENTATION RECORD], counter(page).display())
    })
  show: typography
  set heading(numbering: "1.1")
  counter(heading).update(0)
  v(4mm)
  grid(columns: (1fr, auto), align: horizon,
    sod-label([SOD #number / #category]), sod-chip(upper(state), sod-state-fill(state)))
  v(6mm)
  block[
    #set par(justify: false)
    #text(font: "New Computer Modern Sans", size: 25pt, weight: "bold", hyphenate: false)[#title]
  ]
  v(4mm)
  text(size: 11pt)[#authors.join(", ")]
  v(5mm)
  line(length: 30mm, stroke: 1.5pt + accent-color)
  v(5mm)
  block(width: 100%, fill: bg-light, inset: 11pt)[
    #set par(justify: false)
    #grid(columns: (1.6fr, 1fr), column-gutter: 15pt, row-gutter: 8pt,
      [#sod-label("Record status")\ #sod-value(status)],
      [#sod-label("Created / updated")\ #sod-value([#created / #last-updated])],
      [#sod-label("Discussion")\ #sod-value(discussion)],
      [#sod-label("Topics")\ #sod-value(labels.join(", "))])
  ]
  v(4mm)
  text(size: 9pt, fill: muted-color)[
    *Status of this record.* #if number == sod-placeholder-number [
      #if state == "abandoned" [
        A closed proposal. Consult the successor records named below for the accepted design.
      ] else [
        A provisional draft for review. Proposed behavior and targets are not implemented guarantees.
      ]
    ] else [
      A numbered project record. Its lifecycle state does not certify implementation completeness
      or production readiness; consult its implementation status and evidence.
    ]
  ]
  v(4mm)
  body
}

#let sod-index-page(sod-documents) = configure-document(title: "SQLodin Discussions", [
  #text(font: "New Computer Modern Sans", size: 8pt, tracking: 1pt, fill: accent-color)[
    DESIGN / RATIONALE / EVIDENCE]
  #v(6mm)
  #text(font: "New Computer Modern Sans", size: 28pt, weight: "bold")[SQLodin Discussions]
  #v(4mm)
  #project-authorship
  #v(5mm)
  Design decisions, alternatives and discussion. Numbered records retain their lifecycle states;
  placeholder drafts remain provisional. A committed design is not a production certification.
  #v(6mm)
  #for doc in sod-documents [
    #block(width: 100%, breakable: false, inset: 9pt,
      stroke: (top: 0.6pt + border-color), below: 3mm)[
      #grid(columns: (1fr, auto), gutter: 10pt,
        text(font: "New Computer Modern Sans", size: 13pt, weight: "bold")[SOD #doc.number],
        sod-chip(upper(doc.state), sod-state-fill(doc.state)))
      #v(3pt)
      #text(size: 12pt, weight: "bold")[#doc.title]
      #v(4pt)
      #doc.summary
      #v(4pt)
      #text(size: 8.5pt, fill: muted-color)[#doc.category / Updated #doc.updated]
    ]
  ]
  #block(breakable: false)[
    #text(font: "New Computer Modern Sans", size: 13pt, weight: "bold")[Closed draft]
    #v(4pt)
    *Pinned Upstream Paxos and SQLite Application Correctness* is abandoned as superseded.
    Its accepted design and discussion are incorporated into SODs 0002–0004.
  ]
])
