// Book Theme and Typography for SQLodin
#let ink = rgb("0f172a")
#let blue = rgb("0284c7")
#let blue_light = rgb("f0f9ff")
#let green = rgb("15803d")
#let green_light = rgb("f0fdf4")
#let amber = rgb("b45309")
#let amber_light = rgb("fffbeb")
#let red = rgb("b91c1c")
#let red_light = rgb("fef2f2")
#let gray = rgb("64748b")
#let rule = rgb("e2e8f0")

#let book(body) = {
  set document(
    title: "SQLodin: Distributed Multi-Master SQLite via Rotating Paxos",
    author: "Vikrant Rathore, with assistance from Ronak Rathore",
    keywords: ("Paxos", "SQLite", "multi-master", "sqlite-vec", "FTS5", "consensus", "Odin"),
  )
  set page(
    paper: "a4",
    margin: (inside: 25mm, outside: 20mm, top: 22mm, bottom: 24mm),
    numbering: "1",
    number-align: center,
    header: context {
      if counter(page).get().first() > 1 {
        set text(size: 8.5pt, fill: gray)
        let current-page = here().page()
        let headings = query(heading.where(level: 1)).filter(
          item => item.location().page() <= current-page,
        )
        let chapter = if headings.len() > 0 { headings.last().body } else { [] }
        grid(
          columns: (1fr, 1fr),
          box(width: 100%, clip: true)[SQLodin Architectural Specification],
          box(width: 100%, clip: true, align(right, emph(chapter))),
        )
        line(length: 100%, stroke: 0.4pt + rule)
      }
    },
  )
  set text(
    font: ("Liberation Sans", "DejaVu Sans", "Helvetica Neue", "Arial"),
    size: 10pt,
    fill: ink,
    lang: "en",
    hyphenate: true,
    costs: (orphan: 100%, widow: 100%),
  )
  set smartquote(enabled: false)
  set par(justify: true, linebreaks: "optimized", leading: 0.72em, spacing: 0.72em)
  set heading(numbering: "1.1")
  show heading: set par(justify: false)
  set raw(tab-size: 4)
  show raw: set text(font: ("Liberation Mono", "Menlo", "Courier New"), size: 8.2pt, hyphenate: false)
  set table(stroke: 0.45pt + rule, inset: 6pt)
  show table: set par(justify: false)

  show heading.where(level: 1): it => block(width: 100%, breakable: false)[
    #v(1.5em)
    #text(fill: blue, size: 18pt, weight: "bold")[#it]
    #v(0.6em)
    #line(length: 100%, stroke: 1.2pt + blue)
    #v(0.8em)
  ]

  show heading.where(level: 2): it => block(width: 100%, breakable: false)[
    #v(1.2em)
    #text(fill: ink, size: 13pt, weight: "bold")[#it]
    #v(0.4em)
  ]

  show heading.where(level: 3): it => block(width: 100%, breakable: false)[
    #v(1.0em)
    #text(fill: gray, size: 11pt, weight: "bold")[#it]
    #v(0.3em)
  ]

  body
}

#let callout(title: none, kind: "note", body) = {
  let (bg, border, title-color) = if kind == "tip" {
    (green_light, green, green)
  } else if kind == "warning" {
    (amber_light, amber, amber)
  } else if kind == "danger" {
    (red_light, red, red)
  } else {
    (blue_light, blue, blue)
  }

  block(
    width: 100%,
    fill: bg,
    stroke: (left: 3pt + border),
    inset: (x: 12pt, y: 10pt),
    radius: (right: 4pt),
    spacing: 1.2em,
    [
      #if title != none [
        #text(fill: title-color, weight: "bold", size: 9.5pt)[#title]
        #v(0.3em)
      ]
      #text(fill: ink, size: 9pt)[#body]
    ],
  )
}
