# SQLodin

[Website](https://insanai.github.io/sqlodin/) · [Book](https://insanai.github.io/sqlodin/book/) · [Guides](https://insanai.github.io/sqlodin/guides/) · [Design discussions](https://insanai.github.io/sqlodin/sods/)

SQLodin is a distributed SQL database built with SQLite and Paxos. It supports
multi-master writes: an application can send a write to any voter in the cluster.
Each voter stores the database on disk. Paxos gives writes a common order, and
the service acknowledges them after durable replication and local application.

It is written in Odin and uses the complete, pinned
[paxos-odin](https://github.com/insanai/paxos-odin) library. One executable provides
the server, an interactive SQL client, and a local SQLite shell. A Python client
adds parameter binding, transactions, FTS and vector search, and a SQLAlchemy dialect.

## Where it fits

SQLodin is intended for applications that benefit from SQLite's simple data model
but need to keep serving through the loss of one node: internal tools, job and
inventory records, service metadata, and transactional backends. FTS5 and
exact vector search also support applications that combine structured records with
text or embedding search.

The 0.6.0 server accepts one to five voters with fixed membership. Three voters
can tolerate one unavailable voter; five can tolerate two, provided the remaining
voters can communicate. The cluster needs a majority to make progress. The
underlying Paxos API supports larger compile-time membership bounds; the shipped
server and snapshot format currently cap membership at five. End-to-end release
qualification used three voters, while targeted tests and models also cover five.

Every voter can receive writes, but replication still produces one ordered history
and each SQLite database has one writer. Adding voters does not shard the data or
multiply write capacity. SQL statements and transaction sizes have explicit bounds;
check the [SQL contract](specs/sql-policy.typ) before choosing it for an application.

## Try the command line

Download the archive for your machine from [Releases](https://github.com/insanai/sqlodin/releases).
Packages contain the executable, dependency licenses, and a build manifest.
For example, on an x86-64 Linux machine:

```sh
curl -fLO https://github.com/insanai/sqlodin/releases/latest/download/sqlodin-linux-amd64.tar.gz
tar -xzf sqlodin-linux-amd64.tar.gz
./sqlodin version
./sqlodin local notes.db
```

At the prompt:

```sql
CREATE TABLE note (id INTEGER PRIMARY KEY, body TEXT NOT NULL);
INSERT INTO note VALUES (1, 'Start small. Measure what matters.');
SELECT * FROM note;
.quit
```

This creates a local SQLite file. For a three-voter replicated example, start each voter with its
own data directories, certificates, and a shared membership configuration. The
[service guide](https://insanai.github.io/sqlodin/guides/network-service/) explains the configuration and
certificate requirements. Once a cluster and client configuration are ready:

```sh
./sqlodin serve node.json --create   # first start of each voter
./sqlodin connect client.json
./sqlodin connect client.json --mode json -c 'SELECT * FROM note;'
```

Use `serve node.json` without `--create` on subsequent starts. The interactive
client supports scripts, transactions, savepoints, result formats, and commands
such as `.tables`, `.schema`, `.nodes`, and `.help`. See the
[CLI guide](https://insanai.github.io/sqlodin/guides/cli/) for details. Do not open a running voter's database
with the local shell.

### macOS and Windows

macOS archives are available for Apple Silicon (`macos-arm64`) and Intel
(`macos-amd64`). They are unsigned command-line builds. Linux archives target
x86-64 systems with glibc 2.35 or newer, including Ubuntu 22.04 and later.

On Windows, install an Ubuntu distribution under WSL2, then run the Linux commands
inside it. Keep voter data in the Linux filesystem, rather than a mounted Windows
drive. This release does not include a native Windows executable. macOS builds are
provided for development; release tests run on Linux.

## Use it from Python

The Python package requires Python 3.11 or newer. Until it is published on PyPI,
install it from this repository:

```sh
uv add 'sqlodin @ git+https://github.com/insanai/sqlodin.git@v0.6.0#subdirectory=languages/python'
```

```python
import sqlodin

tls = sqlodin.TLS(ca="ca.pem", cert="app.pem", key="app.key")
with sqlodin.connect(
    [sqlodin.Endpoint("127.0.0.1:7601", "node1.sqlodin.test")],
    cluster="notes",
    tls=tls,
) as db:
    db.execute("CREATE TABLE note (id INTEGER PRIMARY KEY, body TEXT NOT NULL)")
    db.execute("INSERT INTO note VALUES (?, ?)", (1, "Hello from Python"))
    print(db.query("SELECT body FROM note WHERE id = ?", (1,)).one()["body"])
```

The [Python guide](https://insanai.github.io/sqlodin/python/) covers endpoint failover, durable
retry identities, transactions, SQLAlchemy, and text/vector search.

## How it works

Each voter owns a rotating set of consensus slots. It can propose directly into
those slots without forwarding every write to a standing leader. The service
batches durable journal work and reconstructs its application database from that
journal after a crash. Fresh reads consult a quorum before reading an applied
snapshot. Client certificates authenticate both applications and voters.

These choices reduce coordination and storage overhead, but they do not remove
network, disk, or contention costs. Transactions use optimistic conflict checks;
even writes to different rows can conflict. Membership is fixed, upgrades require
a coordinated procedure, and replicas must use matching builds and schemas.

The [book](https://insanai.github.io/sqlodin/book/) develops the design and its limits. The
[specifications](specs/README.md) connect the implementation to TLA+ models,
proof obligations, and targeted fault tests. Those checks cover stated models and
assumptions; they are not a proof of the entire executable. Measured results and
workload definitions are in the book's [benchmark chapter](https://insanai.github.io/sqlodin/book/11_benchmarks/).

## Build from source

Install Odin `dev-2026-09`, Python 3, a C compiler, Make, Perl, and `ar`, then:

```sh
git clone --recurse-submodules https://github.com/insanai/sqlodin.git
cd sqlodin
./build.sh
./bin/sqlodin local notes.db
```

The build verifies pinned sources for SQLite 3.51.3 with FTS5, sqlite-vec 0.1.9,
and OpenSSL 3.5.8, then links them into the executable. No shared SQLite or OpenSSL
installation is needed at runtime. Normal operating-system libraries remain.
See [building](https://insanai.github.io/sqlodin/guides/building/) and [contributing](CONTRIBUTING.md).

Maintainers can publish a binary release by pushing a `v` tag matching the CLI
version. The release workflow tests on Linux and builds Linux and macOS archives.
Python publishing is a separate manual workflow, enabled by the `PYPI_API_TOKEN`
repository secret.

SQLodin is written by Vikrant Rathore, with assistance from Ronak Rathore.
It is available under the [MIT license](LICENSE).
