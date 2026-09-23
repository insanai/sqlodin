#import "book/theme.typ": *
#import "book/figures.typ": *

#show: book

#{
  set heading(numbering: none)
  include "book/00_front.typ"
}
#pagebreak()
#{
  set text(size: 10pt)
  set par(leading: 0.6em)
  outline(title: [Contents], depth: 1)
}
#pagebreak()
#include "book/00_start.typ"
#include "book/01_foundations.typ"
#include "book/02_protocol.typ"
#include "book/03_proofs.typ"
#include "book/03_multimaster_writes.typ"
#include "book/04_sqlite_engine.typ"
#include "book/04_transactions.typ"
#include "book/05_vector_and_fts.typ"
#include "book/06_consistency_and_reads.typ"
#include "book/07_reference.typ"

#pagebreak()
#include "book/08_benchmarks.typ"

#pagebreak()
#include "book/09_durable_benchmarks.typ"

#include "book/10_production_plan.typ"
#include "book/11_candidate_measurements.typ"
#include "book/12_journal_groups.typ"
#include "book/13_network_service.typ"
#include "book/14_self_contained_builds.typ"
#include "book/15_orm_transactions.typ"
#include "book/16_native_benchmarks.typ"
#include "book/17_cli.typ"
