// Preserve diagrams as vectors while exporting prose and tables as HTML.
#let web(body) = {
  show figure: it => context {
    if target() == "html" { html.frame(block(width: 165mm, it)) } else { it }
  }
  show grid: it => context {
    if target() == "html" { html.frame(block(width: 165mm, it)) } else { it }
  }
  body
}
