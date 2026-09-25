#let sod-number = "XXXXX"
#let sod-title = "Pinned Upstream Paxos and SQLite Application Correctness"
#let sod-state = "abandoned"
#let sod-created = "2026-09-22"
#let sod-discussion = "Superseded integration proposal"
#let sod-labels = ("consensus", "storage", "performance")
#let sod-authors = ("Vikrant Rathore, with assistance from Ronak Rathore",)
#let sod-category = "Engineering Discussion"
#let sod-status = "Abandoned; incorporated into SODs 0002–0004"
#let sod-last-updated = "2026-09-25"
#import "../../shared/sod.typ": sod-document
#show: doc => sod-document(
  sod-number, sod-title, doc, authors: sod-authors, state: sod-state,
  created: sod-created, discussion: sod-discussion, labels: sod-labels,
  category: sod-category, status: sod-status, last-updated: sod-last-updated,
)


= Abstract

This draft proposed importing the complete pinned paxos-odin library and making SQLite application
atomic and checked. Its design is incorporated into the numbered architecture and durable-host
records. Keeping an active integration draft would describe a stage that no longer exists.

= Status and Implementation Boundary

*Abandoned as superseded, 25 September 2026.* Abandoned describes the proposal record, not rejection
of the implemented integration. SOD 0002 owns the dependency and application boundary; SOD 0003
owns the proof obligations; SOD 0004 owns grouping, recovery and qualification. The original
`a3e1fd78ec8f0429e5024710189ef77fc31961af` pin is historical, not the current dependency.

= Discussion and Revision Notes

*22 September:* Proposed the complete upstream library instead of a partial protocol copy,
checked SQLite bindings and transaction results, atomic applied watermarks, statement reuse,
shared vector storage and durable identifier reservations. These choices reduced duplicated
protocol work and made host obligations visible. The initial tests and memory measurements did
not qualify a durable network service.

*25 September:* The numbered records now contain the accepted design, alternatives, implementation
boundary and dated follow-up. This closure stub preserves the original reference without promoting
a duplicate proposal or retaining an obsolete list of missing production features.

= References

- #link("0002-sqlodin-architecture.typ")[SOD 0002: architecture and integration].
- #link("0003-mathematical-foundations-and-proofs.typ")[SOD 0003: proof obligations].
- #link("0004-production-sql-and-durable-throughput.typ")[SOD 0004: durable host and qualification].
