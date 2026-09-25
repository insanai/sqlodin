#import "theme.typ": blue, blue_light, green, green_light, amber, amber_light, gray, rule

#let panel(title, body, color: blue, fill: blue_light) = block(
  width: 100%, inset: 10pt, radius: 3pt, fill: fill, stroke: 0.5pt + rule,
  breakable: false)[
  #set par(justify: false)
  #text(font: "New Computer Modern Sans", size: 10pt, weight: "bold", fill: color)[#title]
  #v(4pt)
  #text(size: 9.5pt)[#body]
]

#let steps(items) = grid(columns: items.len(), gutter: 8pt,
  ..items.enumerate().map(((i, item)) => panel([#(i+1). #item.at(0)], item.at(1))))

#let slots() = grid(columns: 6, gutter: 4pt,
  ..range(1, 7).map(s => panel([Slot #s], [Owner #(calc.rem(s - 1, 3) + 1)],
    fill: (blue_light, green_light, amber_light).at(calc.rem(s - 1, 3)))))

#let frontier() = table(columns: (1fr, 1fr, 1fr, 1fr, 1fr, 1fr),
  align: center,
  table.header([Slot 1], [Slot 2], [Slot 3], [Slot 4], [Slot 5], [Slot 6]),
  [Chosen], [Chosen], [Missing], [Chosen], [Chosen], [Open],
  [Applied], [Applied], [Wait], [Wait], [Wait], [Wait],
)

#let recovery-strip() = grid(columns: (2fr, 3fr), gutter: 8pt,
  panel([Certified image: 1 … c], [Application state and retry fences at one prefix.]),
  panel([Retained suffix: c+1 … k], [Replay each chosen transition in order. Preserve local acceptor evidence.],
    color: green, fill: green_light))

#let metric-bar(name, value, maximum, label, color: blue) = grid(
  columns: (85pt, 1fr, 65pt), gutter: 8pt, align: left + horizon,
  text(size: 9pt)[#name],
  block(width: 100%, height: 10pt, fill: blue_light)[
    #rect(width: (100 * value / maximum) * 1%, height: 10pt, fill: color, stroke: none)
  ],
  text(size: 9pt)[#label])
