-------------------------- MODULE SnapshotIdentity --------------------------
EXTENDS Naturals, FiniteSets, Sequences
CONSTANTS MatchKey, DistinctVoters, DurableReceipt
Nodes == {1,2,3}
Keys == {"A", "B"}
VARIABLES staged, stable, receipts, certificates
vars == <<staged, stable, receipts, certificates>>
Init == /\ staged = [n \in Nodes |-> "none"]
        /\ stable = [n \in Nodes |-> "none"]
        /\ receipts = <<>> /\ certificates = {}
\* A key abstracts the exact configuration, engine, generation, prefix and
\* logical-state digest. Hash collision freedom and correct image verification
\* are assumptions. Retained images are immutable throughout this model.
Create(n,k) == /\ staged[n] = "none" /\ stable[n] = "none"
               /\ staged' = [staged EXCEPT ![n] = k]
               /\ UNCHANGED <<stable, receipts, certificates>>
Sync(n) == /\ staged[n] /= "none"
           /\ stable' = [stable EXCEPT ![n] = staged[n]]
           /\ staged' = [staged EXCEPT ![n] = "none"]
           /\ UNCHANGED <<receipts, certificates>>
Crash(n) == /\ staged' = [staged EXCEPT ![n] = "none"]
            /\ UNCHANGED <<stable, receipts, certificates>>
Ack(n,k) == /\ Len(receipts) < 3
            /\ (stable[n] = k \/ (~DurableReceipt /\ staged[n] = k))
            /\ receipts' = Append(receipts, [voter |-> n, key |-> k])
            /\ UNCHANGED <<staged, stable, certificates>>
Eligible(k) == {i \in 1..Len(receipts) : ~MatchKey \/ receipts[i].key = k}
Voters(k) == {receipts[i].voter : i \in Eligible(k)}
Certify(k) == /\ (IF DistinctVoters THEN Cardinality(Voters(k)) >= 2
                 ELSE Cardinality(Eligible(k)) >= 2)
              /\ certificates' = certificates \cup {k}
              /\ UNCHANGED <<staged, stable, receipts>>
Next == (\E n \in Nodes, k \in Keys : Create(n,k) \/ Ack(n,k))
        \/ (\E n \in Nodes : Sync(n) \/ Crash(n))
        \/ (\E k \in Keys : Certify(k))
Spec == Init /\ [][Next]_vars
MatchingDurableQuorum == \A k \in certificates : Cardinality({n \in Nodes : stable[n] = k}) >= 2
=============================================================================
