# SQLodin verification

Vikrant Rathore, with assistance from Ronak Rathore.

The [release record](../docs/releases/2026-09-25.typ) binds the supported scope and evidence.
There is no mandatory soak duration or large-capacity campaign.

- [Multi-master assumptions, agreement, progress and code map](multimaster-refinement.typ)
- [SQL policy](sql-policy.typ), [grouped commits](grouped-sql.typ), [transaction/read order](transaction-order.typ)
- [Generation publication](generation-catalog.typ), [image retirement](image-retirement.typ), [session fences](session-retirement.typ)
- [Recovery and certificate procedures](recovery-bootstrap.typ), [resource contract](resource-contract.typ)
- [Performance and disclosed target shortfalls](service-batching.typ)
- [Verification design and historical discussion](../docs/sod/records/0003-mathematical-foundations-and-proofs.typ)

The retained release evidence checks 59 bounded model cases (including required negative
controls) and 48 inductive obligations. SOD 0005 adds 13 model cases (`OwnedSkip`, `JournalCache`,
`QuorumRead`, seven of them negative controls) and 41 obligations (`OwnedSkipProof`) for the
post-release performance mechanisms. The review adds `QuorumReadReconnect` and its
connection-counting negative control (74 configurations total). The composition argument states the assumptions
and refinement boundaries; it is not a machine-checked proof of the entire executable.

```sh
python3 tools/check_formal.py --jar /path/to/tla2tools.jar --output build/formal/result.json
python3 tools/check_proofs.py --tools build/proof-tools --output build/formal/proofs.json
python3 tools/check_proofs.py --tools build/proof-tools --case OwnedSkipProof --output build/formal/owned-skip.json
```

The runners verify pinned tool hashes, require fresh output paths and retain failures.
