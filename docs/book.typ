#import "book/theme.typ": *
#show: book

#{
  set heading(numbering: none)
  include "book/00_front.typ"
}
#pagebreak()
#{
  heading(level: 1, numbering: none, outlined: false)[Contents]
  set text(size: 9pt)
  set par(leading: 0.3em)
  outline(title: none, depth: 2)
}
#pagebreak()
#include "book/01_start.typ"
#include "book/02_clients.typ"
#include "book/03_search.typ"
#include "book/04_history.typ"
#include "book/05_consensus.typ"
#include "book/06_storage.typ"
#include "book/07_transactions.typ"
#include "book/08_recovery.typ"
#include "book/09_proofs.typ"
#include "book/10_runtime.typ"
#include "book/11_benchmarks.typ"
#include "book/12_reference.typ"
