#let sod-number = "XXXXX"
#let sod-title = "Title Goes Here"
#let sod-state = "prediscussion"
#let sod-created = "YYYY-MM-DD"
#let sod-discussion = "Draft discussion note"
#let sod-labels = ("documentation", "engineering")
#let sod-authors = ("Vikrant Rathore, with assistance from Ronak Rathore",)
#let sod-category = "Engineering Discussion"
#let sod-status = "Internal Draft"
#let sod-last-updated = "None"

#import "../../shared/sod.typ": sod-document

#show: doc => sod-document(
  sod-number,
  sod-title,
  doc,
  authors: sod-authors,
  state: sod-state,
  created: sod-created,
  discussion: sod-discussion,
  labels: sod-labels,
  category: sod-category,
  status: sod-status,
  last-updated: sod-last-updated,
)

= Abstract

State the problem, the proposed direction, and the reason this document exists.

= Status and Implementation Boundary

State what ships today, what is proposed, and what evidence supports the status.
A committed design is not automatically a completed implementation. Date reviews;
preserve historical results with their original workload and revision.

= Introduction

Provide the background and the constraints that make the topic worth discussing now.

= Terminology and Scope

Define the terms used in the document and state what is in scope versus explicitly out of scope.

= Problem Statement

Describe the gap in the current system, workflow, or design.

= Goals and Non-Goals

== Goals
- List the properties the proposal must satisfy.

== Non-Goals
- List adjacent problems that this document does not solve.

= Design Overview

Explain the high-level proposal in a way that lets the reader understand the rest of the document.

= Detailed Design

Break the design into the main mechanisms, data flows, interfaces, or document structures.

= Security & Correctness Considerations

Discuss invariants, fault handling, durability guarantees, and safety proofs.

= Operational Considerations

Document runtime, memory footprint, recovery steps, or contributor workflow implications.

= Validation and Acceptance Gates

Name invariants, failure cases, tests, artifacts and the criteria for each phase.
For performance work, specify matched workloads, timing boundaries and uncertainty.
Separate implementation evidence from proof obligations and future work.

= Alternatives Considered

List the main rejected options and why they were rejected.

= Open Questions

Capture unresolved questions that must be answered before the document can move to active discussion or publication.

= Discussion and Revision Notes

Record dated design discussions: the concern, decision, rationale and consequence. Link evidence
without copying run logs. Preserve superseded measurements as historical observations. Update the
current design and registry together; do not leave contradictory implementation-status paragraphs.
State who authorized a scope or acceptance change when known. Do not invent review consensus.

= References

- Add links to related SOD documents, code, or external papers.
