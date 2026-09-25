----------------------------- MODULE OwnedSlot -----------------------------
EXTENDS Integers, FiniteSets
CONSTANTS Failed, DurableGate
Nodes == {1,2,3}
Live == Nodes \ {Failed}
Values == {10,20}
\* Ballot 0 is exclusively owned by voter 1; ballots 1/2 belong to 2/3.
Ballots == 0..2
Proposer(b) == b + 1
Quorums == {q \in SUBSET Nodes : Cardinality(q) >= 2}
VARIABLES promised, voted, offers, prepared, reports, acks, chosen
vars == <<promised, voted, offers, prepared, reports, acks, chosen>>
Init == /\ promised = [n \in Nodes |-> -1]
        /\ voted = [n \in Nodes |-> [ballot |-> -1, value |-> 0]]
        /\ offers = {} /\ prepared = {} /\ reports = {} /\ acks = {} /\ chosen = {}
Own(v) == /\ 1 \in Live /\ ~ (\E o \in offers : o.ballot = 0)
          /\ offers' = offers \cup {[ballot |-> 0, value |-> v]}
          /\ UNCHANGED <<promised, voted, prepared, reports, acks, chosen>>
Prepare(b) == /\ b > 0 /\ Proposer(b) \in Live
              /\ prepared' = prepared \cup {b}
              /\ UNCHANGED <<promised, voted, offers, reports, acks, chosen>>
Promise(n,b) == /\ n \in Live /\ b \in prepared /\ b > promised[n]
                /\ promised' = [promised EXCEPT ![n] = b]
                /\ reports' = reports \cup {[node |-> n, ballot |-> b,
                                             vote |-> voted[n]]}
                /\ UNCHANGED <<voted, offers, prepared, acks, chosen>>
Reports(b,q) == {r \in reports : r.ballot = b /\ r.node \in q}
Eligible(b,q,v) ==
  LET votes == {r.vote : r \in Reports(b,q)}
      used == {r \in votes : r.ballot >= 0}
  IN IF used = {} THEN v \in Values
     ELSE \E r \in used : r.value = v /\ (\A x \in used : x.ballot <= r.ballot)
Offer(b,q,v) == /\ b > 0 /\ Proposer(b) \in Live
                /\ ~ (\E o \in offers : o.ballot = b)
                /\ \A n \in q : \E r \in reports : r.node = n /\ r.ballot = b
                /\ Eligible(b,q,v)
                /\ offers' = offers \cup {[ballot |-> b, value |-> v]}
                /\ UNCHANGED <<promised, voted, prepared, reports, acks, chosen>>
Vote(n,o) == /\ n \in Live /\ o \in offers /\ o.ballot >= promised[n]
             /\ promised' = [promised EXCEPT ![n] = o.ballot]
             /\ voted' = IF DurableGate THEN [voted EXCEPT ![n] = o] ELSE voted
             /\ acks' = acks \cup {[node |-> n, ballot |-> o.ballot, value |-> o.value]}
             /\ UNCHANGED <<offers, prepared, reports, chosen>>
Decide(o,q) == /\ o \in offers
               /\ \A n \in q : [node |-> n, ballot |-> o.ballot, value |-> o.value] \in acks
               /\ chosen' = chosen \cup {o.value}
               /\ UNCHANGED <<promised, voted, offers, prepared, reports, acks>>
Next == (\E v \in Values : Own(v))
        \/ (\E b \in Ballots : Prepare(b))
        \/ (\E n \in Nodes, b \in Ballots : Promise(n,b))
        \/ (\E b \in Ballots, q \in Quorums, v \in Values : Offer(b,q,v))
        \/ (\E n \in Nodes, o \in offers : Vote(n,o))
        \/ (\E o \in offers, q \in Quorums : Decide(o,q))
Spec == Init /\ [][Next]_vars
FairSpec == Spec
  /\ (\A v \in Values : WF_vars(Own(v)))
  /\ (\A b \in Ballots : WF_vars(Prepare(b)))
  /\ (\A n \in Nodes, b \in Ballots : WF_vars(Promise(n,b)))
  /\ (\A b \in Ballots, q \in Quorums, v \in Values : WF_vars(Offer(b,q,v)))
  /\ (\A n \in Nodes, b \in Ballots, v \in Values :
          WF_vars(Vote(n,[ballot |-> b, value |-> v])))
  /\ (\A b \in Ballots, v \in Values, q \in Quorums :
          WF_vars(Decide([ballot |-> b, value |-> v],q)))
Terminates == <> (chosen /= {})
Agreement == Cardinality(chosen) <= 1
PromiseDominates == \A n \in Nodes : promised[n] >= voted[n].ballot
Validity == chosen \subseteq Values
=============================================================================
