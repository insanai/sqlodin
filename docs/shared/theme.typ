// Shared theme and typography for SQLodin documentation

#let primary-color = rgb("1e293b")
#let secondary-color = rgb("334155")
#let accent-color = rgb("0284c7") // sky-600 for sqlodin
#let muted-color = rgb("64748b")
#let bg-light = rgb("f8fafc")
#let border-color = rgb("e2e8f0")

#let configure-document(
  title: "SQLodin",
  author: "SQLodin Contributors",
  body,
) = {
  set document(title: title, author: author)
  set page(
    paper: "a4",
    margin: (x: 2cm, top: 2.5cm, bottom: 2.5cm),
    numbering: "1",
    header: context {
      if counter(page).get().first() > 1 {
        text(9pt, fill: muted-color, font: ("Liberation Sans", "DejaVu Sans", "Helvetica Neue", "Arial"))[
          #title
          #h(1fr)
          SQLodin Specification
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

  show heading: set par(justify: false)
  show table: set par(justify: false)

  show heading: it => [
    #v(0.6em)
    #text(fill: rgb("0f172a"), weight: "bold")[#it.body]
    #v(0.3em)
  ]

  show raw: it => {
    if it.block {
      block(
        width: 100%,
        fill: bg-light,
        stroke: 0.5pt + border-color,
        inset: 10pt,
        radius: 4pt,
        text(font: ("Liberation Mono", "DejaVu Sans Mono", "Menlo", "Courier New"), size: 9pt)[#it]
      )
    } else {
      box(
        fill: bg-light,
        inset: (x: 3pt, y: 1pt),
        radius: 3pt,
        text(font: ("Liberation Mono", "DejaVu Sans Mono", "Menlo", "Courier New"), size: 9.5pt)[#it]
      )
    }
  }

  body
}
