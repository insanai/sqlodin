#import "shared/theme.typ": configure-document
#show: configure-document.with(title: "SQLodin documentation")

= SQLodin documentation

Written by Vikrant Rathore, with assistance from Ronak Rathore.

== Use SQLodin

Start with the guide for the task you want to complete:

- #link("guides/building.typ")[Build and deploy]: pinned native dependencies,
  supported platforms, offline caches and artifact provenance.
- #link("guides/network-service.typ")[Run the SQL service]: fixed voter configuration,
  authenticated connections, SQL requests and deployment limits.
- #link("guides/cli.typ")[Use the command line]: interactive SQL, scripts, transactions,
  output formats and recovery of uncertain requests.
- #link("../languages/python/README.md")[Use Python]: client setup, FTS/vector search
  and SQLAlchemy. See #link("guides/orm-transactions.typ")[transaction semantics]
  for conflicts, savepoints and retry behavior.
- #link("../specs/recovery-bootstrap.typ")[Operate and recover a cluster]: backup,
  restore, migration, coordinated certificate renewal and fencing old identities.

== Understand the design

The #link("book.typ")[book] provides the narrative explanation. The
#link("sod/index.typ")[SOD index] records architectural decisions and their rationale.
SOD lifecycle status records a design decision; release qualification is separate.

The executable models and precise contracts live in `specs/` alongside their
reproduction tools. Start with the
#link("../specs/multimaster-refinement.typ")[multi-master composition argument],
then the #link("../specs/sql-policy.typ")[SQL policy],
#link("../specs/transaction-order.typ")[transaction and read ordering], and
#link("../specs/resource-contract.typ")[resource contract].
The #link("../specs/README.md")[verification index] links the remaining contracts.

== Evaluate the qualified release

The #link("releases/2026-09-25.typ")[25 September 2026 release record] identifies
the tested candidate, supported scope, explicit acceptance decisions and known limits.
Its #link("../benchmarks/results/verification-20260924/release-decision.json")[machine-readable evidence manifest]
binds the reports and artifacts by hash. Performance goals remain unmet improvement
goals; large-capacity and arbitrary recovery-latency guarantees are not claimed.
Use #link("../benchmarks/README.md")[benchmark methods and results] to interpret
measurements rather than treating an old sample as a current guarantee.

== Follow design discussions

The numbered SODs include dated discussion and revision notes. Architecture and upstream integration
belong to SOD 0002, proof strategy to SOD 0003, and durable-host tradeoffs and qualification decisions
to SOD 0004. Raw failed and successful runs remain in `benchmarks/results/`; historical observations
do not override the current contract or create new release requirements.

== Where documents belong

Keep practical instructions in `guides/`, narrative chapters in `book/`, design
decisions in `sod/`, the existing release decision in `releases/`, and historical discussion inside its owning SOD. Shared typography belongs in `shared/`; generated PDFs belong
in `docs/build/`. Formal contracts and model sources remain together in `specs/`.
Raw experiment data stays in `benchmarks/results/`, linked from documentation.
Typst is the primary document format; README files remain concise entry points.
