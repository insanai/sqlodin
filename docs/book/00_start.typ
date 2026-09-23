#import "theme.typ": callout

= Build and Inspect

The useful first experiment is to compile the library, run its regression suite and inspect a
three-node example. SQLodin supplies an embedded host, test drivers and a native mTLS SQL service.
The `sqlodin` command builds and verifies the project; `sqlodin serve` runs a configured voter.
The final chapter describes its Python client and the remaining production gates.

== Reproduce the local example

Use Odin `dev-2026-09` or newer, Python 3, a C compiler, ar, Make and Perl.
Typst is required for documentation. On macOS and Linux the builder verifies pinned
SQLite 3.51.3, sqlite-vec 0.1.9 and OpenSSL 3.5.8 sources, then links their static
archives. There is no shared database/TLS dependency; normal OS runtime libraries
remain. Build outputs and source caches stay inside the repository.

```sh
git clone --recurse-submodules https://github.com/insanai/sqlodin.git
cd sqlodin
make deps
./build.sh
make test
make example
```

The example submits mutations from three owners and exercises vector and full-text queries.
It uses the in-process memory host. Read `examples/multimaster_search.odin` alongside the output;
its successful execution is an integration smoke check, not a durable deployment.

== Inspect durable behavior on Linux

```sh
make check
make check-durability DURABILITY_REPORT=benchmarks/results/new-crash-run.json
```

The full check runs SQLodin and the pinned upstream tests in debug and optimized configurations,
then seeded simulations. The Linux durability campaign injects failures and kills processes at
selected persistence boundaries. Its JSON names each case and whether the recovered data matched.
Use disposable test directories when running these drivers.

#callout(title: "Proposal is not acknowledgement")[
  A returned proposal slot means the request entered consensus. Client success requires its
  expected value to be durably chosen and applied. Carrying an arbitrary proposed slot into a
  read does not establish read-your-writes.
]

== Follow one durable write

+ Construct a bounded mutation with explicit values and deterministic SQL behavior.
+ Submit through `durable.propose`; serialize access to the host.
+ Drive copied peer packets and ticks. Required journal writes commit before dependent effects
  become visible. A reachable quorum chooses a value; earlier slots must also be decided.
+ Apply the contiguous prefix and its watermark atomically in SQLite.
+ Check `durable.acknowledged` for the expected value before returning success.

`bench/realworld/main.odin` and `tests/test_durable.odin` are concrete host integrations.
They show the transport loop and recovery setup; they do not supply a production network protocol.
