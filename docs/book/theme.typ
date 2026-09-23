#import "../shared/theme.typ": typography, project-authorship
#let ink = rgb("182e3b")
#let blue = rgb("166777")
#let blue_light = rgb("edf5f6")
#let green = rgb("326d59")
#let green_light = rgb("eef5f0")
#let amber = rgb("926322")
#let amber_light = rgb("faf4e8")
#let red = rgb("994d44")
#let red_light = rgb("faf0ed")
#let gray = rgb("526773")
#let rule = rgb("d5dfe2")

#let book(body) = {
  set document(title: "SQLodin: Architecture, Durability and Performance",
    author: project-authorship,
    keywords: ("Paxos", "SQLite", "multi-master", "Odin", "durability"))
  set page(paper: "a4", margin: (inside: 24mm, outside: 22mm, top: 23mm, bottom: 23mm),
    numbering: "1",
    header: context {
      if here().page() > 1 {
        set text(font: "New Computer Modern Sans", size: 8pt, fill: gray)
        grid(columns: (1fr, auto), [SQLodin], [ARCHITECTURE / DURABILITY / PERFORMANCE])
        line(length: 100%, stroke: 0.5pt + rule)
      }
    },
    footer: context {
      set text(font: "New Computer Modern Sans", size: 8pt, fill: gray)
      grid(columns: (1fr, auto), [SQLodin / September 2026], counter(page).display())
    })
  show: typography
  show heading.where(level: 1): it => {
    pagebreak(weak: true)
    block(above: 4mm, below: 6mm)[
      #text(size: 23pt, fill: ink)[#it]
      #v(2mm)
      #line(length: 28mm, stroke: 1.5pt + blue)
    ]
  }
  body
}

#let callout(title: none, kind: "note", body) = {
  let (bg, border) = if kind == "tip" { (green_light, green) }
    else if kind == "warning" { (amber_light, amber) }
    else if kind == "danger" { (red_light, red) }
    else { (blue_light, blue) }
  block(width: 100%, fill: bg, stroke: (left: 2pt + border),
    inset: (x: 11pt, y: 9pt), above: 8pt, below: 8pt, breakable: false)[
    #set par(justify: false)
    #if title != none [
      #text(font: "New Computer Modern Sans", size: 9.5pt, weight: "bold", fill: border)[#title]
      #v(3pt)
    ]
    #text(size: 10pt)[#body]
  ]
}
