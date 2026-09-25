// SQLodin Discussions (SOD) Combined Bundle
// Compiles all registered SOD records into a single consolidated reference.

#import "../shared/sod.typ": sod-index-page
#import "registry.typ": sod-documents

#sod-index-page(sod-documents)

#pagebreak()
#include "records/0001-sod-process.typ"

#pagebreak()
#include "records/0002-sqlodin-architecture.typ"

#pagebreak()
#include "records/0003-mathematical-foundations-and-proofs.typ"

#pagebreak()
#include "records/0004-production-sql-and-durable-throughput.typ"

#pagebreak()
#include "records/0005-durable-turn-and-fast-skip-learning.typ"
