------------------------- MODULE ImageRetirement ----------------------------
EXTENDS Naturals, FiniteSets, TLC
CONSTANTS GuardSuccessor, GuardCurrent, GuardPrevious
Nodes == 1..3
Prefixes == 1..2
VARIABLES files, receipts, chosen, seen, current, previous
vars == <<files, receipts, chosen, seen, current, previous>>
Init == /\ files = {} /\ receipts = {} /\ chosen = 0
        /\ seen = [n \in Nodes |-> 0]
        /\ current = [n \in Nodes |-> 0]
        /\ previous = [n \in Nodes |-> 0]
Capture(n,p) == /\ <<n,p>> \notin receipts /\ p >= seen[n]
                /\ files' = files \cup {<<n,p>>}
                /\ receipts' = receipts \cup {<<n,p>>}
                /\ UNCHANGED <<chosen, seen, current, previous>>
Seal(p) == /\ p > chosen
           /\ Cardinality({n \in Nodes: <<n,p>> \in receipts}) >= 2
           /\ chosen' = p
           /\ UNCHANGED <<files, receipts, seen, current, previous>>
Learn(n) == /\ chosen > seen[n]
            /\ seen' = [seen EXCEPT ![n] = chosen]
            /\ UNCHANGED <<files, receipts, chosen, current, previous>>
Install(n) == /\ seen[n] > current[n] /\ <<n,seen[n]>> \in files
              /\ current' = [current EXCEPT ![n] = seen[n]]
              /\ previous' = [previous EXCEPT ![n] = current[n]]
              /\ UNCHANGED <<files, receipts, chosen, seen>>
Retire(n,p) == /\ <<n,p>> \in files
               /\ (~GuardSuccessor \/ p < seen[n])
               /\ (~GuardCurrent \/ p # current[n])
               /\ (~GuardPrevious \/ p # previous[n])
               /\ files' = files \ {<<n,p>>}
               /\ UNCHANGED <<receipts, chosen, seen, current, previous>>
Next == (\E n \in Nodes, p \in Prefixes: Capture(n,p) \/ Retire(n,p)) \/
        (\E p \in Prefixes: Seal(p)) \/ (\E n \in Nodes: Learn(n) \/ Install(n))
Spec == Init /\ [][Next]_vars
LatestQuorumRetained == chosen = 0 \/ Cardinality({n \in Nodes: <<n,chosen>> \in files}) >= 2
ActiveImageRetained == \A n \in Nodes: current[n] = 0 \/ <<n,current[n]>> \in files
PreviousImageRetained == \A n \in Nodes: previous[n] = 0 \/ <<n,previous[n]>> \in files
=============================================================================
