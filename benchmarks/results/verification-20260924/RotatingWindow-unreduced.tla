--------------------------- MODULE RotatingWindow ---------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Failed, Producer, Target, Window, Skip, Revoke, Release, GuardReuse
Nodes == {1,2,3}
Live == Nodes \ {Failed}
Slots == 1..Target
Cells == 0..(Window-1)
Owner(s) == ((s-1) % 3)+1
Cell(s) == (s-1) % Window
Quorums == {q \in SUBSET Live : Cardinality(q) >= 2}
VARIABLES offered, seen, votes, chosen, applied, floor, held, lost
vars == <<offered, seen, votes, chosen, applied, floor, held, lost>>
Init == /\ offered = {} /\ votes = {} /\ chosen = {}
        /\ seen = [n \in Nodes |-> 0]
        /\ applied = [n \in Nodes |-> 0]
        /\ floor = [n \in Nodes |-> 0]
        /\ held = [n \in Nodes |-> [c \in Cells |-> 0]]
        /\ lost = FALSE
\* Composition lemma, not a second implementation of Synod. One immutable
\* value per decree and safe phase-one selection are supplied by OwnedSlot's
\* agreement argument. Votes here are durable evidence. The recovery offer is
\* the completed phase-one boundary under an eventually non-preempted campaign.
Room(n,s) == /\ s > floor[n] /\ s <= floor[n]+Window
             /\ (held[n][Cell(s)] = s \/ held[n][Cell(s)] <= floor[n])
Suggest(n,s) == /\ n \in Live /\ Owner(s) = n /\ s \notin offered
                /\ Room(n,s)
                /\ (Producer = 0 \/ n = Producer \/ (Skip /\ s <= seen[n]))
                /\ offered' = offered \cup {s}
                /\ seen' = [seen EXCEPT ![n] = IF @ < s THEN s ELSE @]
                /\ UNCHANGED <<votes, chosen, applied, floor, held, lost>>
Observe(n,s) == /\ n \in Live /\ s \in offered /\ seen[n] < s
                /\ seen' = [seen EXCEPT ![n] = s]
                /\ UNCHANGED <<offered, votes, chosen, applied, floor, held, lost>>
Recover(n) == LET s == applied[n]+1 IN
              /\ Revoke /\ n \in Live /\ s <= seen[n] /\ s \in Slots
              /\ Owner(s) = Failed /\ s \notin offered /\ Room(n,s)
              /\ offered' = offered \cup {s}
              /\ UNCHANGED <<seen, votes, chosen, applied, floor, held, lost>>
Vote(n,s) == /\ n \in Live /\ s \in offered /\ <<n,s>> \notin votes
             /\ (~GuardReuse \/ Room(n,s))
             /\ votes' = votes \cup {<<n,s>>}
             /\ held' = [held EXCEPT ![n][Cell(s)] = s]
             /\ lost' = (lost \/ (held[n][Cell(s)] > floor[n] /\ held[n][Cell(s)] /= s))
             /\ UNCHANGED <<offered, seen, chosen, applied, floor>>
Decide(s) == /\ s \in offered /\ s \notin chosen
             /\ \E q \in Quorums : \A n \in q : <<n,s>> \in votes
             /\ chosen' = chosen \cup {s}
             /\ UNCHANGED <<offered, seen, votes, applied, floor, held, lost>>
\* Application includes eventual authenticated learning/replay of a decision.
\* Arbitrary ordering and repetition of these enabled actions model delivery;
\* weak fairness requires eventual successful retransmission, not no packet loss.
Apply(n) == /\ n \in Live /\ applied[n]+1 \in chosen
            /\ applied' = [applied EXCEPT ![n] = @+1]
            /\ UNCHANGED <<offered, seen, votes, chosen, floor, held, lost>>
Free(n) == /\ Release /\ n \in Live /\ floor[n] < applied[n]
           /\ floor' = [floor EXCEPT ![n] = applied[n]]
           /\ UNCHANGED <<offered, seen, votes, chosen, applied, held, lost>>
Next == (\E n \in Nodes, s \in Slots : Suggest(n,s) \/ Observe(n,s) \/ Vote(n,s))
        \/ (\E n \in Nodes : Recover(n) \/ Apply(n) \/ Free(n))
        \/ (\E s \in Slots : Decide(s))
Spec == Init /\ [][Next]_vars
        /\ (\A n \in Nodes, s \in Slots :
               WF_vars(Suggest(n,s)) /\ WF_vars(Observe(n,s)) /\ WF_vars(Vote(n,s)))
        /\ (\A n \in Nodes : WF_vars(Recover(n)) /\ WF_vars(Apply(n)) /\ WF_vars(Free(n)))
        /\ (\A s \in Slots : WF_vars(Decide(s)))
TypeOK == /\ offered \subseteq Slots /\ chosen \subseteq offered
          /\ votes \subseteq (Live \X Slots)
          /\ seen \in [Nodes -> 0..Target] /\ applied \in [Nodes -> 0..Target]
          /\ floor \in [Nodes -> 0..Target]
          /\ held \in [Nodes -> [Cells -> 0..Target]] /\ lost \in BOOLEAN
AppliedPrefix == \A n \in Nodes : /\ (1..applied[n]) \subseteq chosen
                                 /\ floor[n] <= applied[n]
DurableQuorum == \A s \in chosen : \E q \in Quorums : \A n \in q : <<n,s>> \in votes
HeldSlot == ~lost
Converges == <> (\A n \in Live : applied[n] = Target)
=============================================================================
