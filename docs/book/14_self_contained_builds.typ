#import "theme.typ": callout
#let local = json("../../benchmarks/results/local-orm-build.json")
#let linux = json("../../benchmarks/results/linux-orm-build.json")
#assert(local.complete and linux.complete)
#pagebreak()
= Self-Contained Native Builds

The same build path produces the standalone CLI and dependencies for embedded Odin
applications on macOS and Linux. SQLite, sqlite-vec and OpenSSL are compiled from
pinned, verified sources and linked as static archives. Deployment does not require
shared database or TLS libraries. The complete upstream Paxos library remains a
pinned dependency rather than a copied implementation.

#table(columns: (1fr, 0.7fr, 2fr),
  table.header([*Dependency*], [*Pin*], [*Build contract*]),
  [SQLite], [#local.native.sqlite], [FTS5 enabled; dynamic extension loading disabled.],
  [sqlite-vec], [#local.native.sqlite_vec], [Static registration; filesystem helpers disabled.],
  [OpenSSL], [#local.native.openssl], [Static SSL/crypto; no loadable providers or engines.],
)

```sh
git submodule update --init --recursive
python3 tools/build_cli.py --jobs 4
# Once sources and archives are cached:
python3 tools/build_cli.py --offline
# Embedded engine only:
python3 tools/build_native.py --sqlite-only
```

Prerequisites are Odin, Python 3, a C compiler and platform SDK/headers, ar, Make and
Perl. Nothing is installed into system directories. Downloads live in
`build/downloads`; archives and component manifests live in `build/native`.
The builder validates source hashes, flags, compiler/platform identity and cached
artifact hashes before reuse. A corrupt archive invalidates the cache.

The CLI build automatically inspects dynamic linkage and records a manifest beside
the executable. Both macOS arm64 and Linux x86_64 passed this check. The JSON records
used for this page contain dependency versions, archive hashes and full linkage output.
The generated license directory accompanies redistributable binaries.

#callout(title: "What self-contained means here", kind: "note")[
Database and TLS implementations are part of the binary. Normal operating-system
libraries remain dynamic: macOS uses libSystem and Cocoa; Linux uses its platform
runtime. A Linux build still needs a compatible libc baseline. Cross-compilation,
fully static libc and bit-for-bit toolchain reproducibility are not claimed.
]

The SQL service loads explicit CA, certificate and private-key files. Automatic
OpenSSL configuration loading is disabled, so external provider configuration does
not become a hidden runtime dependency. The bundled OpenSSL utility is only a
build/test convenience. Embedded applications importing the database package do not
link TLS unless they also import the service or transport.

A native dependency update requires changing the pin, rebuilding and rerunning
correctness checks. Updating a system package cannot patch a statically linked
binary. SQLite build changes may also invalidate the durable engine fingerprint;
there is no silent migration. See `docs/building.md` for deployment and cache details.
