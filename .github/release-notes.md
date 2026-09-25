SQLodin provides a replicated SQLite service, an interactive SQL client, and a bundled local SQLite shell.

- Linux: x86-64, glibc 2.35 or newer (Ubuntu 22.04 and later).
- macOS: Apple Silicon and Intel; unsigned builds for development.
- Windows: use the Linux archive inside Ubuntu on WSL2. A native Windows port is deferred.

Extract the archive and run `./sqlodin local notes.db`, or see the repository README and service guide to configure a three-voter cluster. SQLite, sqlite-vec and OpenSSL are linked into the executable. Each archive includes dependency licenses and a build manifest. SHA256SUMS covers all release archives and the Linux unit-test report.

Release tests run on Linux only. The server accepts one to five fixed voters with matching builds and deterministic, bounded SQL. End-to-end release qualification used three voters; targeted tests and models also cover five. Any voter can accept writes; a majority is required for progress. The repository retains the formal-model checks, fault-test evidence, and measured performance results. These are evidence within stated assumptions, not a guarantee against every failure.

The Python client is available from the repository. PyPI publication will follow separately.
