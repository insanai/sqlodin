# Contributing to SQLodin

Welcome to SQLodin! SQLodin is engineered to be an exceptionally rigorous, mechanically sympathetic,
and idiomatic implementation of distributed multi-master SQLite consensus in Odin.

Before contributing, please read this document to understand our architectural constraints, coding
standards, verification pipeline, and the **SQLodin Discussion (SOD)** RFC process.

---

## The Zen of Odin for InsanAI Systems

SQLodin adheres to strict mechanical constraints defined in [SOD-0001](docs/sod/records/0001-sod-process.typ):

1. **File Length Limit:** No single source file (`.odin`) may exceed **1,408 lines**. If a module grows
   beyond this limit, decompose it along clean architectural seams.
2. **Line Column Limit:** Hard limit of **108 columns**, soft limit of **99 columns**. Wrap lines cleanly.
3. **Procedure Logic Limit:** No single procedure may exceed **70 lines of executable logic** (excluding
   blank lines, comments, and `#assert` declarations). Break complex flows into small, focused sub-procedures.
4. **Zero-Heap Consensus Transitions:** The core consensus state machine (`MultiMaster_Node`, `Ledger`,
   `Effects`, `consensus.odin`, `ownership.odin`) MUST NEVER allocate on the heap during normal transitions.
   Fixed capacity arrays and small-array collections are used exclusively.
5. **Clear Failure Modes:** Every error returned by the library must have an Elm-style diagnostic
   entry in `src/errors.odin` featuring a `-- BANNER --` header, concise explanation, and an actionable `Hint:`.

---

## Verification Pipeline

Every change must pass our complete verification pipeline before merging:

```bash
# 1. Run all unit tests
make test

# 2. Run structural checks and compiler strict style
make vet

# 3. Run full verification suite (tests, contracts, chaos simulation, smoke benchmarks)
make check
```

You can verify your code formatting and structural constraints locally at any time:
```bash
python3 tools/check_style.py --soft
```

---

## SQLodin Discussions (SODs)

Non-trivial architectural changes, wire protocol adjustments, or storage engine modifications must be
proposed as a **SQLodin Discussion (SOD)** RFC.

### Creating a Draft SOD
```bash
./bin/sqlodin sod new <short-slug>
```
This generates `docs/sod/records/XXXXX-<slug>.typ` using the official Typst RFC template.

### Promoting a Draft to Active Discussion
```bash
./bin/sqlodin sod promote <short-slug>
```
This assigns the next sequential SOD number, renames the file, and registers it in `docs/sod/registry.typ`.

### Compiling SOD Documents
```bash
make docs
```
Compiles `docs/build/sqlodin-book.pdf`, `docs/build/sod-index.pdf`, and `docs/build/sod-bundle.pdf`.
