------------------------------ MODULE QuorumRead ------------------------------
\* SOD 0005 M6: a fresh read closes its cohort, observes the highest seen slot
\* at this voter and at ReadQuorum - 1 peers, then answers once its contiguous
\* applied prefix reaches the largest observation. Slot s holds write s. A
\* write is acknowledged after application at any voter, so it is chosen.
\* ReportApplied (peers report applied prefixes) and NoPeers (answer without a
\* peer observation) are negative controls.
EXTENDS Naturals, FiniteSets
CONSTANTS ReportApplied, NoPeers
Nodes == {1,2,3}
Slots == 1..2
Quorums == {q \in SUBSET Nodes : Cardinality(q) >= 2}
Max(a, b) == IF a >= b THEN a ELSE b
VARIABLES voted, highest, chosen, applied, acked, done, phase, need, bound, replies, reader
vars == <<voted, highest, chosen, applied, acked, done, phase, need, bound, replies, reader>>
Init == /\ voted = [n \in Nodes |-> {}] /\ highest = [n \in Nodes |-> 0]
        /\ chosen = {} /\ applied = [n \in Nodes |-> 0] /\ acked = {} /\ done = {}
        /\ phase = "idle" /\ need = {} /\ bound = 0 /\ replies = {} /\ reader = 1
Frame == <<phase, need, bound, replies, reader>>
\* A durable vote raises highest_seen, which never decreases (restart resumes above the ledger).
Vote(n, s) == /\ s \notin voted[n]
              /\ voted' = [voted EXCEPT ![n] = @ \cup {s}]
              /\ highest' = [highest EXCEPT ![n] = Max(@, s)]
              /\ UNCHANGED <<chosen, applied, acked, done>> /\ UNCHANGED Frame
Choose(s, q) == /\ \A n \in q : s \in voted[n] /\ chosen' = chosen \cup {s}
                /\ UNCHANGED <<voted, highest, applied, acked, done>> /\ UNCHANGED Frame
Apply(n) == /\ applied[n] + 1 \in chosen /\ applied' = [applied EXCEPT ![n] = @ + 1]
            /\ highest' = [highest EXCEPT ![n] = Max(@, applied[n] + 1)]
            /\ UNCHANGED <<voted, chosen, acked, done>> /\ UNCHANGED Frame
Ack(n) == /\ acked' = acked \cup (1..applied[n])
          /\ UNCHANGED <<voted, highest, chosen, applied, done>> /\ UNCHANGED Frame
\* Invocation fixes what the read must observe: acknowledged writes and every
\* write a previously answered read observed. Membership closes at Begin.
Begin(r) == /\ phase = "idle" /\ phase' = "querying" /\ reader' = r
            /\ need' = acked \cup done /\ bound' = highest[r] /\ replies' = {}
            /\ UNCHANGED <<voted, highest, chosen, applied, acked, done>>
Report(p) == IF ReportApplied THEN applied[p] ELSE highest[p]
Reply(p) == /\ phase = "querying" /\ p /= reader /\ p \notin replies
            /\ replies' = replies \cup {p} /\ bound' = Max(bound, Report(p))
            /\ UNCHANGED <<voted, highest, chosen, applied, acked, done, phase, need, reader>>
Answer == /\ phase = "querying"
          /\ NoPeers \/ Cardinality(replies) >= 1
          /\ applied[reader] >= bound
          /\ phase' = IF need \subseteq 1..applied[reader] THEN "idle" ELSE "stale"
          /\ done' = done \cup (1..applied[reader])
          /\ UNCHANGED <<voted, highest, chosen, applied, acked, need, bound, replies, reader>>
Next == (\E n \in Nodes, s \in Slots : Vote(n, s)) \/ (\E s \in Slots, q \in Quorums : Choose(s, q))
        \/ (\E n \in Nodes : Apply(n) \/ Ack(n) \/ Begin(n) \/ Reply(n)) \/ Answer
Spec == Init /\ [][Next]_vars
\* Linearizable freshness: every write completed before invocation is visible.
RealTimeOrder == phase /= "stale"
ChosenBelowHighest == \A n \in Nodes : \A s \in voted[n] : s <= highest[n]
=============================================================================
