# Native mTLS foundation and remaining service work

Vikrant Rathore, with assistance from Ronak Rathore. Updated 2026-09-23.

`transport/mtls` is an optional **experimental Odin/OpenSSL 3 transport primitive**.
The [native SQL service](network-service.md) now wraps it with a listener, bounded
event loop, identity/role checks, peer compatibility handshake and SQL result protocol.
Enrollment and dynamic membership remain unimplemented. The embedded database does not import or
require OpenSSL. The stopped eight-hour qualification campaign used
its frozen SSH fixture.

The installed September 2026 Odin distribution has cryptographic primitives but
no core TLS package. SQLodin uses a small OpenSSL 3 foreign-function interface for
protocol and certificate validation. Certificate enrollment remains separate from
consensus membership. See the [Odin core catalog](https://pkg.odin-lang.org/core/).

## Implemented boundary

- TLS 1.3 only, mutual certificate verification against an explicitly supplied CA,
  and no verification callback that can override failures.
- Exact configured DNS subject-alternative-name verification in both directions.
  Wildcards and common-name fallback are disabled. The expected peer identity
  must come from trusted configuration, not a peer's unauthenticated hello.
- Certificate/key consistency checks, certificate purpose and validity checks,
  no session tickets and no early data.
- Nonblocking connected sockets, explicit `Want_Read`/`Want_Write` states, and no
  application reads or writes before the handshake authenticates the peer.
- At most 64 KiB per I/O call. The caller owns framing limits, total connection
  budgets, event-loop fairness and absolute handshake/request deadlines.
- Explicit context/stream destruction. The socket remains caller-owned. Streams
  must not be copied or used concurrently; after a retry status, retry the same
  operation with the same unchanged buffer. Teardown currently aborts TLS and
  requires the caller to close the socket; graceful close-notify is still open.

The executable must ignore SIGPIPE before networking and keep that policy in
force. The package deliberately does not change process-global signal handlers.
The test executable demonstrates that responsibility. An early harness counted
SIGPIPE termination as an acceptable negative result; that report is retained
and explicitly invalidated. The corrected tests require a normal error exit.

`tools/check_mtls.py` builds the native Odin probe and creates short-lived test
certificates in a temporary directory. Fifteen cases cover native bidirectional
application exchange, fragmented Python/OpenSSL interoperability, wrong client
and server identity, untrusted CA, wildcard/CN fallback, incorrect purpose,
expired certificates, key mismatch, blocking descriptors, missing client
certificates, TLS 1.2, plaintext and stalled handshakes. The fixture uses inherited
socket pairs; it does not test a deployed SQL service or peer discovery.

```sh
python3 tools/build_native.py
python3 tools/check_mtls.py --openssl build/native/openssl --output new-mtls-check.json
```

The Odin binding links the pinned static OpenSSL archives on macOS and Linux.
The service disables automatic OpenSSL configuration loading and uses explicit
CA/certificate/key paths. No external provider modules or system OpenSSL install
are required; OS cryptographic entropy is still required.


## Remaining membership and operator work

The native listener binds identities to a configured cluster ID, node ID, fixed voter
plan and SQL-client allowlist. There is no dynamic configuration epoch protocol yet. Peers, SQL clients and administrative enrollment identities
need separate authorization; possession of a CA-signed certificate alone is not
permission to vote or change the cluster. Require compatible protocol, mutation,
SQLite and SQL-policy fingerprints before accepting replication traffic.

Enrollment should generate a private key and CSR on the joining machine and use
an expiring single-use operator token, pinned issuer identity, durable token
consumption and explicit role authorization. Do not distribute the CA private key
to every voter. Rotation, revocation, clock/expiry behavior, safe reload, graceful
shutdown and connection exhaustion still need implementation and failure tests.

Adding a voting machine requires a consensus-decided membership transition and
safe state transfer. The current durable host has fixed membership. Certificate
enrollment must not silently change its voter list. Implement and verify certified
snapshot/catch-up, the upstream reconfiguration contract, configuration fencing,
and retired-node rejection before exposing an add/replace-voter command. A valid
certificate must not revive a removed node ID. These remain SOD 0004 release gates.
