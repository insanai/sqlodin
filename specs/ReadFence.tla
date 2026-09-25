----------------------------- MODULE ReadFence -----------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS FreshMarker, AppliedGate
Slots == 1..4
Nodes == {1,2}
Writes == {"w1", "w2"}
VARIABLES chosen, applied, acknowledged, reads, active, ticket, required, answers
vars == <<chosen, applied, acknowledged, reads, active, ticket, required, answers>>
Init == /\ chosen = [s \in Slots |-> "empty"]
        /\ applied = [n \in Nodes |-> 0]
        /\ acknowledged = {} /\ reads = 0 /\ active = FALSE
        /\ ticket = 0 /\ required = {} /\ answers = {}
\* Abstract agreement/durability: one immutable decision per slot. No quorum,
\* network, revocation or SQL determinism claim is made by this model.
Write(s,w) == /\ chosen[s] = "empty"
              /\ \A t \in Slots : chosen[t] /= w
              /\ chosen' = [chosen EXCEPT ![s] = w]
              /\ UNCHANGED <<applied, acknowledged, reads, active, ticket, required, answers>>
Skip(s) == /\ chosen[s] = "empty"
           /\ chosen' = [chosen EXCEPT ![s] = "skip"]
           /\ UNCHANGED <<applied, acknowledged, reads, active, ticket, required, answers>>
Apply(n) == /\ applied[n] < 4 /\ chosen[applied[n]+1] /= "empty"
            /\ applied' = [applied EXCEPT ![n] = @+1]
            /\ UNCHANGED <<chosen, acknowledged, reads, active, ticket, required, answers>>
Visible(n) == {chosen[s] : s \in 1..applied[n]} \cap Writes
Ack == /\ acknowledged' = acknowledged \cup Visible(1)
       /\ UNCHANGED <<chosen, applied, reads, active, ticket, required, answers>>
Begin(s) == /\ ~active /\ reads < 2
            /\ (chosen[s] = "empty" \/ (~FreshMarker /\ chosen[s] = "read"))
            /\ chosen' = [chosen EXCEPT ![s] = "read"]
            /\ active' = TRUE /\ reads' = reads+1 /\ ticket' = s
            /\ required' = acknowledged
            /\ UNCHANGED <<applied, acknowledged, answers>>
Return == /\ active /\ (~AppliedGate \/ applied[2] >= ticket)
          /\ answers' = answers \cup {[need |-> required, seen |-> Visible(2),
                                       prefix |-> applied[2], fence |-> ticket]}
          /\ active' = FALSE
          /\ UNCHANGED <<chosen, applied, acknowledged, reads, ticket, required>>
Next == (\E s \in Slots, w \in Writes : Write(s,w))
        \/ (\E s \in Slots : Skip(s) \/ Begin(s))
        \/ (\E n \in Nodes : Apply(n)) \/ Ack \/ Return
Spec == Init /\ [][Next]_vars
RealTimeOrder == \A a \in answers : a.need \subseteq a.seen
AppliedBeforeSnapshot == \A a \in answers : a.prefix >= a.fence
=============================================================================
