------------------------------ MODULE OwnedSkip ------------------------------
\* One owned decree under rotating ownership with Mencius-style fast learning
\* of the owner's no-op (SOD 0005, M2). Round 0 belongs to voter 1; rounds 1/2
\* belong to revokers 2/3. A revoker offers the highest reported vote, or the
\* no-op when its quorum reports none. A learner that receives the owner's
\* round-0 no-op Accept records the no-op as decided without a quorum. With
\* three voters (write quorum two), a voter whose own durable round-0 vote
\* matches the owner's durable round-0 vote has seen a quorum (SOD 0005 M5).
EXTENDS Integers, FiniteSets
CONSTANTS Failed, AnyRevoke, Amnesia, LearnUnvoted
Nodes == {1,2,3}
Live == Nodes \ {Failed}
Noop == 0
Values == {Noop, 10}
Ballots == 0..2
Proposer(b) == b + 1
Quorums == {q \in SUBSET Nodes : Cardinality(q) >= 2}
None == [ballot |-> -1, value |-> -1]
VARIABLES promised, voted, offers, prepared, reports, acks, chosen, learned
vars == <<promised, voted, offers, prepared, reports, acks, chosen, learned>>
Init == /\ promised = [n \in Nodes |-> -1]
        /\ voted = [n \in Nodes |-> None]
        /\ offers = {} /\ prepared = {} /\ reports = {} /\ acks = {}
        /\ chosen = {} /\ learned = {}
\* The owner's round-0 vote is durable before its Accept exists (P2). Amnesia
\* models an owner that lost that vote and suggests again in the same slot.
Own(v) == /\ 1 \in Live /\ promised[1] <= 0
          /\ Amnesia \/ ~ (\E o \in offers : o.ballot = 0)
          /\ offers' = offers \cup {[ballot |-> 0, value |-> v]}
          /\ promised' = [promised EXCEPT ![1] = 0]
          /\ voted' = [voted EXCEPT ![1] = [ballot |-> 0, value |-> v]]
          /\ acks' = acks \cup {[node |-> 1, ballot |-> 0, value |-> v]}
          /\ UNCHANGED <<prepared, reports, chosen, learned>>
Prepare(b) == /\ b > 0 /\ Proposer(b) \in Live
              /\ prepared' = prepared \cup {b}
              /\ UNCHANGED <<promised, voted, offers, reports, acks, chosen, learned>>
Promise(n,b) == /\ n \in Live /\ b \in prepared /\ b > promised[n]
                /\ promised' = [promised EXCEPT ![n] = b]
                /\ reports' = reports \cup {[node |-> n, ballot |-> b, vote |-> voted[n]]}
                /\ UNCHANGED <<voted, offers, prepared, acks, chosen, learned>>
Reports(b,q) == {r \in reports : r.ballot = b /\ r.node \in q}
\* B3 as implemented by maybe_resolve_chunk: the highest reported vote, else
\* the host no-op. AnyRevoke is the negative control that offers any value.
Eligible(b,q,v) ==
  LET votes == {r.vote : r \in Reports(b,q)}
      used == {r \in votes : r.ballot >= 0}
  IN IF used = {} THEN (IF AnyRevoke THEN v \in Values ELSE v = Noop)
     ELSE \E r \in used : r.value = v /\ (\A x \in used : x.ballot <= r.ballot)
Offer(b,q,v) == /\ b > 0 /\ Proposer(b) \in Live
                /\ ~ (\E o \in offers : o.ballot = b)
                /\ \A n \in q : \E r \in reports : r.node = n /\ r.ballot = b
                /\ Eligible(b,q,v)
                /\ offers' = offers \cup {[ballot |-> b, value |-> v]}
                /\ UNCHANGED <<promised, voted, prepared, reports, acks, chosen, learned>>
Vote(n,o) == /\ n \in Live /\ o \in offers /\ o.ballot >= promised[n]
             /\ promised' = [promised EXCEPT ![n] = o.ballot]
             /\ voted' = [voted EXCEPT ![n] = o]
             /\ acks' = acks \cup {[node |-> n, ballot |-> o.ballot, value |-> o.value]}
             /\ UNCHANGED <<offers, prepared, reports, chosen, learned>>
Decide(o,q) == /\ o \in offers
               /\ \A n \in q : [node |-> n, ballot |-> o.ballot, value |-> o.value] \in acks
               /\ chosen' = chosen \cup {o.value}
               /\ UNCHANGED <<promised, voted, offers, prepared, reports, acks, learned>>
\* SOD 0005 M2: any live voter receiving the owner's round-0 no-op learns it.
FastLearn(n) == /\ n \in Live
                /\ [ballot |-> 0, value |-> Noop] \in offers
                /\ learned' = learned \cup {Noop}
                /\ UNCHANGED <<promised, voted, offers, prepared, reports, acks, chosen>>
\* SOD 0005 M5: {owner, n} is a write quorum of durable votes for (0, v).
\* LearnUnvoted is the negative control: learn from the Accept alone.
VoteLearn(n) == /\ n \in Live /\ n /= 1
                /\ \E v \in Values :
                     /\ [node |-> 1, ballot |-> 0, value |-> v] \in acks
                     /\ IF LearnUnvoted THEN [ballot |-> 0, value |-> v] \in offers
                        ELSE voted[n] = [ballot |-> 0, value |-> v]
                     /\ learned' = learned \cup {v}
                /\ UNCHANGED <<promised, voted, offers, prepared, reports, acks, chosen>>
Next == (\E v \in Values : Own(v))
        \/ (\E b \in Ballots : Prepare(b))
        \/ (\E n \in Nodes, b \in Ballots : Promise(n,b))
        \/ (\E b \in Ballots, q \in Quorums, v \in Values : Offer(b,q,v))
        \/ (\E n \in Nodes, o \in offers : Vote(n,o))
        \/ (\E o \in offers, q \in Quorums : Decide(o,q))
        \/ (\E n \in Nodes : FastLearn(n))
        \/ (\E n \in Nodes : VoteLearn(n))
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
\* A fast-learned no-op never disagrees with any quorum decision.
LearnedAgreement == Cardinality(chosen \cup learned) <= 1
\* The inductive core proved in OwnedSkipProof.tla.
NoopDeterminacy == [ballot |-> 0, value |-> Noop] \in offers =>
                     \A o \in offers : o.value = Noop
PromiseDominates == \A n \in Nodes : promised[n] >= voted[n].ballot
=============================================================================
