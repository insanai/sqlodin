#let sod-number = "0001"
#let sod-title = "The SQLodin Discussion Process"
#let sod-state = "committed"
#let sod-created = "2026-09-22"
#let sod-discussion = "The SOD process, the Zen of Odin for InsanAI, and its enforced structural constraints"
#let sod-labels = ("process", "documentation", "cli", "standards")
#let sod-authors = ("Vikrant Rathore, with assistance from Ronak Rathore",)
#let sod-category = "Process Memo"
#let sod-status = "Committed"
#let sod-last-updated = "2026-09-25"

#import "../../shared/sod.typ": *
#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge
#import "@preview/cetz:0.5.2"

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

This document defines the *SQLodin Discussions (SOD)* RFC process, metadata schema, authoring lifecycle, and CLI tooling for `sqlodin`. Modeled directly after the Paxos Odin Discussions (POD) from `paxos-odin` and inspired by the ensodiscussions (EDS) architecture, SOD records serve as versioned architectural specifications, multi-master consensus derivations, and process memos for distributed SQLite engineering. Their purpose is to explain decisions, alternatives, and unresolved questions, not to collect implementation logs.

*SOD* stands for *SQLODIN Discussions* — durable records for discussion on improvement, architecture, and enhancements of SQLodin.

= Status and Implementation Boundary

Committed records may be corrected with a dated update; published records are frozen under the lifecycle defined below. Status describes a design decision, not a claim that every proposed feature ships. The registry and each record must agree.

#table(
  columns: (auto, auto, 1fr),
  inset: 6pt,
  stroke: 0.5pt + rgb("#cbd5e1"),
  table.header([*SOD*], [*State*], [*Implementation or evidence boundary*]),
  [0001], [Committed], [Active process, Typst editorial policy, and Zen structural limits.],
  [0002], [Committed], [Implemented fixed-voter architecture, durable SQL, native service, fresh reads and bounded clients.],
  [0003], [Committed], [Compositional protocol and host arguments, bounded models and selected inductive proofs; no whole-executable proof.],
  [0004], [Committed], [Implemented fixed-voter host; correctness qualification accepted with disclosed performance shortfalls.],
)

The registry is the index of accepted decisions, not an implementation checklist. Keep lifecycle
state separate from implementation status. Committed means accepted; Published requires an explicit
finalization decision and freezes the record. Passing tests alone does not publish a SOD.

= Record Structure and Revision Rules

Use `docs/sod/template/rfc-template.typ` for engineering proposals. Keep these sections in order:
Abstract; Status and Implementation Boundary; Introduction; Terminology and Scope; Problem Statement;
Goals and Non-Goals; High-Level Architecture & Workflow; Detailed Design; Invariants & Correctness Guarantees;
Security & Operational Considerations; Resource Budgets & Performance Targets; Validation and Acceptance Gates;
Alternatives Considered; Open Questions; Discussion and Revision Notes; References. A process memo may use
policy-specific sections, as this record does. Explain any inapplicable engineering section rather than silently losing its purpose.

The status section dates the review and distinguishes implemented behavior, proposed behavior,
qualified scope, and known limits. Validation names the evidence and its revision boundary; it does
not turn a hypothesis into an achieved guarantee. Alternatives explain the choice and its cost.
Open questions identify unresolved decisions, with future scope separated from release blockers.

Discussion notes record the problem raised, the decision, its reason, and its consequence. Attribute
owner decisions where known; do not invent reviewer consensus or meeting history. Fold historical
development into the relevant SOD. Do not create separate progress diaries or historical document
collections. Keep raw results in `benchmarks/results/` and protocol contracts and models in `specs/`.
The existing release record binds a candidate's qualification; it is not another design proposal.

For a committed-record revision, update the current design in place, add a dated decision note and
update the registry date and summary together. Preserve original measurement attribution and failed
results. Do not append a new status that contradicts an obsolete "current" section above it. A
materially different proposal should reference the decision it replaces. A superseded draft becomes
Abandoned with a successor pointer; it does not need a number merely to close it. Published records
are frozen: a replacement needs a new record and an explicit supersession reference.

= Introduction

Distributed database libraries require uncompromising precision. Subtle design choices — such as multi-master slot partitioning, write-ahead durability order, logical mutation replication versus physical WAL page capture, conflict-free primary keys, and vector search indexing — cannot be captured solely in inline source comments or transient issue tracker threads.

SOD provides a structured, versioned, Typst-rendered specification pipeline embedded in the repository.

= The SOD Lifecycle

A SOD document progresses through five standardized states:

1. *Prediscussion (Draft)*: A placeholder file named `XXXXX-<slug>.typ` created from `docs/sod/template/rfc-template.typ`. In this state, authors outline ideas and gather initial informal feedback.
2. *Discussion*: A numbered document (`NNNN-<slug>.typ`) actively reviewed by maintainers and contributors.
3. *Committed*: Consensus has been reached, the design is accepted, and implementation is scheduled or completed.
4. *Published*: The specification is finalized and frozen as a permanent reference.
5. *Abandoned*: The proposal was withdrawn or superseded by another record.

#diagram-card(caption: [Figure 1: The SQLodin Discussion (SOD) state machine and promotion lifecycle.])[
  #scale(78%, reflow: true)[#fletcher.diagram(
    node-stroke: 0.8pt,
    spacing: (1.7cm, 1.2cm),
    node((0,0), [Prediscussion\ (`XXXXX-topic.typ`)], fill: rgb("#fef3c7"), stroke: 0.8pt + rgb("#d97706"), corner-radius: 4pt, name: <draft>),
    node((1,0), [Discussion\ (`NNNN-topic.typ`)], fill: rgb("#dcfce7"), stroke: 0.8pt + rgb("#059669"), corner-radius: 4pt, name: <discuss>),
    node((2,0), [Committed\ (Accepted RFC)], fill: rgb("#ede9fe"), stroke: 0.8pt + rgb("#7c3aed"), corner-radius: 4pt, name: <commit>),
    node((3,0), [Published\ (Frozen Record)], fill: rgb("#dbeafe"), stroke: 0.8pt + rgb("#1e40af"), corner-radius: 4pt, name: <publish>),
    node((1,1), [Abandoned\ (Superseded Draft)], fill: rgb("#e5e7eb"), stroke: 0.8pt + rgb("#64748b"), corner-radius: 4pt, name: <abandon>),

    edge(<draft>, <discuss>, "->", label: text(size: 7.5pt)[`sod promote`], stroke: 0.8pt + rgb("#059669")),
    edge(<discuss>, <commit>, "->", label: text(size: 7.5pt)[consensus reached], stroke: 0.8pt + rgb("#7c3aed")),
    edge(<commit>, <publish>, "->", label: text(size: 7.5pt)[implementation frozen], stroke: 0.8pt + rgb("#1e40af")),
    edge(<draft>, <abandon>, "->", label: text(size: 7.5pt)[withdrawn / replaced], stroke: 0.7pt + rgb("#64748b")),
    edge(<discuss>, <abandon>, "->", stroke: 0.7pt + rgb("#64748b")),
  )]
]

= Numbering & Promotion Workflow

To prevent Git merge conflicts on sequence numbers across branches, new proposals begin with the placeholder `XXXXX`.

The `sqlodin` automation manages the entire lifecycle:
```sh
# 1. Create a new draft
./bin/sqlodin sod new multimaster-read-fences

# 2. List all active records and draft placeholders
./bin/sqlodin sod list

# 3. Promote the draft to the next permanent 4-digit number
./bin/sqlodin sod promote multimaster-read-fences

# 4. Compile PDFs via Typst
./bin/sqlodin docs sod
```

= Registry and Compilation

Every promoted record is registered in `docs/sod/registry.typ`. The document suite is compiled to PDF using the installed `typst` binary:
- Individual records: `docs/build/sod-NNNN-<slug>.pdf`
- Master Index: `docs/build/sod-index.pdf`
- Complete Book: `docs/build/sqlodin-book.pdf`

#diagram-card(caption: [Figure 2: The SQLodin documentation build and artifact compilation pipeline.])[
  #scale(80%, reflow: true)[#cetz.canvas({
    import cetz.draw: *

    let box-elem(pos, dim, fill, strk, title, detail) = {
      let (x, y) = pos
      let (w, h) = dim
      rect((x, y), (x + w, y + h), fill: fill, stroke: 0.8pt + strk, radius: 0.12)
      content((x + w/2, y + h*0.65), text(weight: "bold", size: 8.5pt, fill: rgb("#0f172a"))[#title])
      content((x + w/2, y + h*0.3), text(size: 6.8pt, fill: rgb("#475569"))[#detail])
    }

    // Input sources
    box-elem((0, 3.2), (3.4, 1.2), rgb("#f8fafc"), rgb("#cbd5e1"), "SOD Records", "docs/sod/records/*.typ")
    box-elem((0, 1.6), (3.4, 1.2), rgb("#f8fafc"), rgb("#cbd5e1"), "Registry & Template", "docs/sod/registry.typ & template")
    box-elem((0, 0.0), (3.4, 1.2), rgb("#f8fafc"), rgb("#cbd5e1"), "Architectural Book", "docs/book.typ & chapters")

    // Compiler engine
    box-elem((4.4, 1.4), (2.8, 1.6), rgb("#e6f4f6"), rgb("#166777"), "Typst Compiler", "typst 0.15.1 + tools/build_docs.py")

    // Outputs
    box-elem((8.2, 3.2), (3.4, 1.2), rgb("#ecfdf5"), rgb("#059669"), "Individual SOD PDFs", "docs/build/sod-NNNN.pdf")
    box-elem((8.2, 1.6), (3.4, 1.2), rgb("#ede9fe"), rgb("#7c3aed"), "Consolidated Bundle & Index", "docs/build/sod-{bundle,index}.pdf")
    box-elem((8.2, 0.0), (3.4, 1.2), rgb("#dbeafe"), rgb("#1e40af"), "Full System Book", "docs/build/sqlodin-book.pdf")

    // Connectors
    line((3.4, 3.8), (4.4, 2.4), mark: (end: ">", fill: rgb("#64748b")), stroke: 0.8pt + rgb("#64748b"))
    line((3.4, 2.2), (4.4, 2.2), mark: (end: ">", fill: rgb("#64748b")), stroke: 0.8pt + rgb("#64748b"))
    line((3.4, 0.6), (4.4, 2.0), mark: (end: ">", fill: rgb("#64748b")), stroke: 0.8pt + rgb("#64748b"))

    line((7.2, 2.4), (8.2, 3.8), mark: (end: ">", fill: rgb("#059669")), stroke: 0.8pt + rgb("#059669"))
    line((7.2, 2.2), (8.2, 2.2), mark: (end: ">", fill: rgb("#7c3aed")), stroke: 0.8pt + rgb("#7c3aed"))
    line((7.2, 2.0), (8.2, 0.6), mark: (end: ">", fill: rgb("#1e40af")), stroke: 0.8pt + rgb("#1e40af"))
  })]
]

= The Zen of Odin for InsanAI

Every SOD, and every line of Odin in this repository, is written under one short creed. It is quoted in full so that a reviewer can point at the line a change violates.

#zen-box[
  Data is real; code is just the stream. \
  Explicit is better than a hidden scheme. \
  Simple blocks beat abstractions built too high, \
  A mere mortal should see how the segments tie. \
  Keep close to the metal, let allocations show, \
  Pass your contexts cleanly so the lifetimes flow. \
  Errors are values, never cast aside, \
  Handle them explicitly; let nothing hide. \
  Fail with grace, let diagnostics guide: \
  Show the break, the hint, the fix inside. \
  Design for speed, let safety lead the pace, \
  Waste no cycle, leave no leaking trace. \
  Keep it simple to use, explain, and maintain, \
  So years from now, the logic remains plain. \
  Coherence beats purity when real problems strike, \
  But structure your memory as hardware would like.
]

= Structural Constraints

The creed is enforced by `tools/check_style.py`, which `make vet`, `make check`, and the `sqlodin check` command run before anything else. A hard limit fails the build.

#invariant-box(title: "Source Boundaries Enforced by CI")[
  - *Maximum file length:* A single source file must not exceed 1,408 physical lines, including comments and blank lines. Modular separation is mandatory.
  - *Line width bounds:* Soft limit at 99 columns; hard limit at 108 columns (tabs count as 4 columns). A line exceeding 108 columns fails the build.
  - *Procedure code density:* The execution body of a procedure must not exceed 70 lines (excluding blank lines, comments, and divider lines).
]

== Elm-style error handling and diagnostics

- *Actionable reporting:* An error does not merely state what failed; it explains why and provides an actionable path to resolution. In code this is the `Error` enum plus `explain_error`, a static table with one entry per value, and a test that fails when a value has no entry.
- *Diagnostic structure:* Every error block or runtime diagnostic carries three parts: the *context* (the failing input or state), the *hint* (the assumption or constraint that was breached), and the *remediation* (how to fix it).

== Performance and longevity architecture

- *Resource-optimum design:* Memory layouts favour mechanical sympathy: contiguous arrays (the `Ledger` columns and bitmaps, inline small array effect buffers), predictable transformations, and no redundant heap allocations during consensus transitions.
- *Safety through visibility:* Performance never justifies unvetted cleverness. The library relies on Odin's type checking, explicit compile-time bounds (`#assert`), and runtime durability gates rather than implicit trust.
- *Direct owner admission:* The adapter enables upstream rotating ownership. Healthy slot choice can take one quorum round; durable SQL completion also waits for persistence and the contiguous prefix.

= Documentation Policy and Editorial Guidance

Typst is the canonical format for project documentation. Markdown is reserved for GitHub-facing entry pages (`README.md`, `CONTRIBUTING.md`).

Keep teaching material in `docs/book/`, design and process records in `docs/sod/records/`. Benchmark drivers belong under `bench/`. Historical design discussion belongs in the relevant SOD; raw evidence remains separate. Temporary notes do not belong in the repository.

= Discussion and Revision Notes

#decision-box(title: "22 September 2026: Foundation")[
  Established the numbered Typst discussion process (SOD), metadata schema, and structural code limits.
]

#decision-box(title: "25 September 2026: Alignment with RFC Standards")[
  Clarified the template, revision rules, and separation of lifecycle state from implementation qualification. Updated the shared SOD design system inspired by ensodiscussions (EDS), integrating Fletcher workflows and CeTZ architectural diagrams.
]

= References

- POD 0001: Defines the upstream Paxos Odin discussion process.
- POD 0002: Records the pure state-machine architecture.
- The SQLodin engineering template is `docs/sod/template/rfc-template.typ`.
- ensodiscussions (EDS): Design and discussion records (`docs/ensodiscussions/`).
