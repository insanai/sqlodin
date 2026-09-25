# Contributing to SQLodin

Contributions should make SQLodin easier to use, understand, or operate. Explain the
problem, the resulting behavior, and the evidence behind the change. For changes to
the design, follow the [SOD process](docs/sod/records/0001-sod-process.typ).

## The Zen of Odin for InsanAI Systems

SQLodin adheres to strict mechanical constraints defined in [SOD-0001](docs/sod/records/0001-sod-process.typ):

1. **File Length Limit:** No single source file (`.odin`) may exceed **1,408 lines**. If a module grows
   beyond this limit, decompose it along clean architectural seams.
2. **Line Column Limit:** Hard limit of **108 columns**, soft limit of **99 columns**. Wrap lines cleanly.
3. **Procedure Logic Limit:** No single procedure may exceed **70 lines of executable logic** (excluding
   blank lines, comments, and `#assert` declarations). Break complex flows into small, focused sub-procedures.
4. **Zero-Heap Consensus Transitions:** The core consensus state machine (`MultiMaster_Node`, `Ledger`,
   `Effects` in the pinned `deps/paxos-odin` library) MUST NEVER allocate on the heap during normal transitions.
   Fixed capacity arrays and small-array collections are used exclusively.
5. **Clear Failure Modes:** Every error returned by the library must have an Elm-style diagnostic
   entry in `src/errors.odin` featuring a `-- BANNER --` header, concise explanation, and an actionable `Hint:`.

---

## Verification Pipeline

Pull requests run Linux checks selected by the files changed:

- Documentation-only edits run source style and CI selection checks, without a native build.
- Python changes run the locked Python test environment and benchmark-harness tests.
- Native changes type-check and vet the CLI, run debug unit tests and compiler contracts,
  and run one bounded fault-simulation seed with one, three, and five nodes.
- Consensus dependency updates also run the upstream unit tests.
- TLA+ model or configuration changes run the changed models with their negative controls,
  plus a small set of durability and read checks. Register new model configurations in
  `tools/check_formal.py`. The manual CI workflow can run the full bounded-model matrix.
  TLAPS proof changes need a separate proof-checking workflow; they are not passed off
  as successful TLC checks.

The stable **PR checks** job reports the combined result. Older runs on the same
branch are cancelled. Native dependency archives are cached and checked by the
build scripts before reuse. Tests run only on Linux. Multi-platform builds belong
to the release workflow, not every pull request.

For a local Linux run of the short native checks:

```sh
./build.sh
python3 tools/check_ci.py
```

Use targeted crash, network, SQL, or formal checks for the behavior being changed.
Record the commands and results in the PR. Run `make check` for broader qualification
when the change needs it; it includes both build profiles and more fault scenarios.
Benchmarks and long-running experiments are explicit work, not routine PR gates.

## Releases

Keep the versions in `cli/main.odin`, `src/sqlodin.odin`, the Python package metadata,
`__init__.py`, and `uv.lock` aligned. Push an annotated tag such as `v0.6.1` to start
the binary release workflow. It tests on Linux and builds Linux and macOS archives.
All builds must pass before the draft becomes public. Published assets are not
replaced by a rerun. Windows users use the Linux archive under WSL2.

Run **Publish Python package** manually on the same tag to upload to PyPI. It uses
the locked test environment, checks the distributions, and requires the repository
secret `PYPI_API_TOKEN`. No publishing credentials are exposed to PR jobs.

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
Promotion is not implementation qualification. Follow SOD 0001 and the template: record the problem,
decision, alternatives, current implementation boundary and dated discussion. Update the registry
with each accepted revision. Keep development history in its owning SOD, not a separate diary.

### Compiling SOD Documents
```bash
make docs
```
Compiles `docs/build/sqlodin-book.pdf`, `docs/build/sod-index.pdf`, and `docs/build/sod-bundle.pdf`.

## Consensus dependency

Initialize the complete pinned library with `make deps` (or clone with `--recurse-submodules`).
Do not copy protocol code into SQLodin or edit files inside the submodule for application changes.
Change the dependency through an explicit reviewed gitlink update and update `tools/check.py`'s tested
revision. Run upstream and SQLodin tests in both profiles before adopting a new pin.

`src/paxos.odin` is an adapter, not a second Paxos implementation. Consensus operations return
`Consensus_Error` (the upstream enum); application operations return SQLodin's `Error`.
`explain_error` accepts either. Host code must consume/copy all borrowed effect payloads before
stepping that node again. Follow the host obligations in the [protocol specifications](specs/README.md).

## Documentation placement

Use the [documentation index](docs/index.typ) as the reader entry point. Keep task-oriented
instructions in `docs/guides/`, narrative chapters in `docs/book/`, numbered decisions in
`docs/sod/`, release qualification in `docs/releases/`, and historical discussion within the relevant SOD. Formal contracts and executable models stay together in `specs/`;
raw evidence stays in `benchmarks/results/`. Avoid adding loose documents to `docs/`.

The [website](https://insanai.github.io/sqlodin/) is generated from these sources.
Run `uv run tools/build_site.py` with Typst 0.15.1 installed to build HTML, PDFs and
the search index in `build/site`. The Pages workflow checks document links on Linux,
attaches previews to documentation PRs, and deploys only from `main`. Site presentation
lives in `docs/site`; keep technical prose in its existing book, guide, SOD or spec.
