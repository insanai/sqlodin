// SQLodin Discussions (SOD) Registry
// Automatically updated by `sqlodin sod promote <slug>`

#let sod-documents = (
  (
    number: "0001",
    slug: "sod-process",
    title: "The SQLodin Discussion Process",
    state: "committed",
    area: "process",
    category: "Process Memo",
    status: "Committed",
    created: "2026-09-22",
    updated: "2026-09-22",
    summary: "Defines the SOD lifecycle, numbering workflow, Typst project layout, registry, and CLI automation for the sqlodin project.",
    source: "docs/sod/records/0001-sod-process.typ",
    pdf: "sod-0001-sod-process.pdf",
  ),
  (
    number: "0002",
    slug: "sqlodin-architecture",
    title: "SQLodin Architecture: Multi-Master Replicated SQLite Protocol",
    state: "committed",
    area: "architecture",
    category: "Architectural Specification",
    status: "Committed",
    created: "2026-09-22",
    updated: "2026-09-22",
    summary: "Specifies the multi-master SQLite protocol, rotating slot ownership, 1-RTT fast path without leader forwarding, logical mutation replication, Snowflake keys, sqlite-vec vector search, and SQLite FTS5.",
    source: "docs/sod/records/0002-sqlodin-architecture.typ",
    pdf: "sod-0002-sqlodin-architecture.pdf",
  ),
)
