#import "theme.typ": callout
#import "figures.typ": steps
= Build, connect and run SQL
<start>

SQLodin offers three entry points. The local shell opens an ordinary SQLite file.
The cluster client talks to a running SQLodin voter. The embedded Odin library lets
an application own the host loop. These paths have different responsibilities.

#figure(steps((
  ([Local shell], [`sqlodin local notes.db` opens one local database.]),
  ([Cluster client], [`sqlodin connect client.json` sends authenticated requests.]),
  ([Native voter], [`sqlodin serve node.json` owns replication and storage.]),
)), caption: [Choose the interface by who owns the database and replication.])

#callout(title: "Keep the two shells separate")[
`sqlodin local` bypasses replication. Use it for standalone files, never to modify
an active voter's database. Use `sqlodin connect` for replicated SQL.
]

== Build the native binary

Install Odin, Python 3, a C compiler and platform headers, `ar`, Make and Perl.
The verified builds use macOS arm64 and Linux x86_64. SQLite, sqlite-vec and OpenSSL are C libraries, so the build also needs a C compiler.

```sh
git clone --recurse-submodules https://github.com/insanai/sqlodin.git
cd sqlodin
./build.sh
bin/sqlodin version
bin/sqlodin local notes.db 'SELECT 2 + 3;'
```

The build verifies pinned source hashes and links the database and TLS libraries
statically. It also embeds the shell from the same SQLite release. The resulting
binary needs normal OS runtime libraries; it is not a fully static libc binary.
No installed SQLite or OpenSSL executable is needed to run the service.

`build/downloads/` holds verified downloads. `build/native/` holds compiled archives.
Use `python3 tools/build_cli.py --offline` when those caches are already present.
Keep the build manifest and license notices with the binary. A library security
update requires a new pinned build; updating a system shared library cannot change
code already linked into SQLodin.

== Form a fixed cluster

Declare the same sorted members on every voter, with distinct IDs, directories and
leaf credentials. This node-1 plan uses example addresses and absolute paths:

```json
{
  "cluster": "orders", "node": 1,
  "listen": "10.175.52.19:7600", "data": "/srv/sqlodin/orders/node1",
  "certificate": "/srv/sqlodin/tls/node1.pem",
  "key": "/srv/sqlodin/tls/node1.key", "ca": "/srv/sqlodin/tls/ca.pem",
  "members": [
    {"id":1,"address":"10.175.52.19:7600","identity":"node1.sqlodin.test"},
    {"id":2,"address":"10.175.52.20:7600","identity":"node2.sqlodin.test"},
    {"id":3,"address":"10.175.52.21:7600","identity":"node3.sqlodin.test"}
  ],
  "clients": ["app.orders.sqlodin.test"]
}
```

Provision CA-signed certificates first. Each voter certificate needs the exact DNS
SAN in its member entry and both `serverAuth` and `clientAuth` usage. A SQL client
needs `clientAuth` and a SAN named in `clients`. Keep the CA private key off the voters.
Use restrictive permissions for private keys and data directories. Fixture certificate
generators in the test tools are not an enrollment service.

Create node-2 and node-3 plans by changing the node ID, listen address, data path and
leaf key/certificate. Keep the cluster name, trust and member list consistent.
Addresses currently use numeric IPv4. Paths should be absolute.

```sh
mkdir -p -m 700 /srv/sqlodin/orders/node1
bin/sqlodin serve node1.json --create   # first start only
# After stopping the process:
bin/sqlodin serve node1.json            # reopen existing state
```

`--create` refuses existing database state. Ordinary startup refuses missing state.
Do not recreate an empty database under an old voter identity: the old promises
and votes are part of the safety argument. @recovery explains replacement.

== Connect a client

A CLI client selects one endpoint. The expected DNS identity is checked against the
server certificate; it does not replace CA verification.

```json
{
  "cluster": "orders",
  "address": "10.175.52.19:7600",
  "identity": "node1.sqlodin.test",
  "certificate": "/srv/sqlodin/tls/app.pem",
  "key": "/srv/sqlodin/tls/app.key",
  "ca": "/srv/sqlodin/tls/ca.pem"
}
```

```sh
bin/sqlodin connect client.json
```

```sql
CREATE TABLE account(id INTEGER PRIMARY KEY, balance INTEGER NOT NULL);
INSERT INTO account VALUES (1, 100), (2, 0);
SELECT id, balance FROM account ORDER BY id;
```

SQL ends with a semicolon. Use `.help` for commands and `.mode json` for machine output.
A script is not automatically atomic; @clients explains `BEGIN` and `COMMIT`.

A fresh query through each endpoint checks more than a listening socket. A lone
minority voter can answer local status but cannot complete a new quorum-backed read.

Build details are in #link("../guides/building.typ")[the build guide]. Certificate
and protocol fields are in #link("../guides/network-service.typ")[the service guide].
