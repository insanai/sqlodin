#import "theme.typ": callout
#import "figures.typ": recovery-strip, steps
= Snapshots, restart and replacement
<recovery>

A bounded in-memory consensus window does not bound disk history. A long-running voter
needs a way to replace an old application prefix with a verified image, preserve the
remaining acceptor facts, and delete only history that recovery no longer needs.

#figure(recovery-strip(), caption: [An image replaces an applied prefix, not the local acceptor's identity.])

== Certify a logical prefix

A snapshot worker pins an application read transaction at prefix $c$. It copies the image,
checks its contents, and computes a logical digest. The image includes user state, schema,
application revision and retry fences. Two valid SQLite files may have different page
layouts while representing the same logical state; logical and physical digests serve
different purposes.

A snapshot key binds configuration, engine, logical digest, generation and prefix. A receipt
binds that key, the reporting voter, physical file hash and size. The voter must durably
retain its verified image before issuing a receipt. The authenticated transport binds the
receipt to the configured sender.

A certificate contains a majority of distinct, matching receipts. Duplicate voters do not
increase its weight. The host then chooses a seal binding the complete certificate through
Paxos. A locally copied file or a receipt alone is not permission to trim.

#figure(steps((
  ([Build image], [Copy, verify, hash and synchronize a pinned prefix.]),
  ([Certify], [Collect distinct matching receipts; choose the full certificate seal.]),
  ([Publish], [Build a recoverable local generation, then select it durably.]),
)), caption: [Each arrow carries a stronger condition. A partial image cannot skip ahead to publication.])

== Publish an old-or-new generation

A private replacement combines the certified application image with the recipient's
local consensus suffix. It preserves promises, accepted values, chosen work, durable ID
reservations and request fences. A background worker builds the base; the service then
copies bounded deltas while the live voter continues to run.

Each owner turn copies at most 128 journal records or 1 MiB, then applies at most one
chosen SQL transaction to the private replacement. One small SQL record can generate
many data pages, so a record-count limit alone is not an application-work bound.
The final publication checks that the replacement matches the required live frontiers
and identity. A FULL root-catalog transaction selects the new generation.

Crashing before publication leaves the old generation selected. Crashing after it selects
the complete new generation. The exact predecessor is retained. Retirement uses a durable
ownership inventory, refuses active/predecessor or unowned paths, deletes eligible files,
synchronizes the directory, then forgets their inventory entry. An interrupted deletion
can retry missing files; it must never infer ownership from a filename alone.

Image retirement separately protects images needed by the active generation, predecessor
and latest certificate. These rules matter because a correct new snapshot does not imply
that every old file is immediately dispensable.

== Rejoin with state intact

A temporarily offline voter first tries retained history. Beyond the retained prefix,
it can fetch a certified image in authenticated bounded chunks and install a generation.
The healthy majority can continue serving. Transfer cannot import the donor's promises
or accepted state as if they belonged to the recipient.

Automatic maintenance uses one job, with a 256 MiB tail or fifteen-minute dirty-history
trigger. Retained consensus history has an 8 GiB cap and admission reserves. Application
files, predecessor images and staging space are separate disk costs. `maintenance: "manual"`
disables automatic initiation/publication for deliberate offline workflows.

Maintenance bounds do not preempt blocked kernel I/O. Recovery retains its integrity
checks; @benchmarks reports the observed startup times.

== Back up an application recovery point

Stop the source voter; the other two may continue serving. Use a new destination:

```sh
sqlodin backup source-node.json /backups/orders-cut
sqlodin verify-backup /backups/orders-cut
```

The backup contains a verified application image and manifest. It is not a quorum
certificate and does not include later acknowledgements. To take a lossless recovery
cut, first quiesce clients, resolve in-flight outcomes, obtain a fresh quorum read on
the source, stop it and take the backup. Keep the old deployment fenced afterward.

== Replace lost state in a new namespace

A lost disk cannot be repaired by creating a blank acceptor under its old identity.
The supported procedure restores the fixed group from one verified backup into a
globally unused cluster namespace and fresh directories. Stop every old process and
its restart automation. Restore the same backup on every new voter before starting them:

```sh
sqlodin restore /backups/orders-cut new-node1.json --new-cluster
sqlodin serve new-node1.json
```

Repeat the restore for the other new voter plans. Check fresh quorum reads through
all endpoints. The backup prefix and retry fences survive; donor promises, votes and
ID reservations do not become the new acceptor's state. A genesis digest binds peers
to the same restored initial image. Incomplete restores refuse startup.

== Upgrade and renew credentials deliberately

For a supported format-4 source, quiesce and stop all voters, explicitly configure
`storage_format: 4`, and run `sqlodin migrate OLD.json NEW-DIRECTORY` separately for
each voter. Preserve original files. Activate the compatible format-5 group together.
Rollback to the originals is safe only before activating the migrated group; after new
acknowledgements, a stale source is not a rollback target. No rolling upgrade is promised.

Certificate renewal also uses coordinated shutdown. Replace trust and leaf credentials
on voters and clients, preserve configured principals, restart, and check fresh reads.
Existing TLS sessions do not terminate merely because a certificate expires. Removing
old trust and closing old sessions are both needed. Dynamic enrollment and membership
changes are outside this fixed-voter procedure.

Follow #link("../../specs/recovery-bootstrap.typ")[the operating contract] for the
full backup, restore, migration and certificate conditions.
