#import "book/theme.typ": *
#import "book/figures.typ": *

#show: book

#include "book/00_front.typ"
#pagebreak()
#outline(title: [Table of Contents], depth: 2)
#pagebreak()
#include "book/01_foundations.typ"
#include "book/02_protocol.typ"
#include "book/03_multimaster_writes.typ"
#include "book/04_sqlite_engine.typ"
#include "book/05_vector_and_fts.typ"
#include "book/06_consistency_and_reads.typ"
#include "book/07_reference.typ"
