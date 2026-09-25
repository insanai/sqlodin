----------------------------- MODULE ReadCohort -----------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS CloseMembership, AppliedGate, PreserveOtherWaiters
Slots == 1..4
Nodes == {1,2}
Readers == {"r1","r2"}
Writes == {"w1","w2"}
VARIABLES chosen, applied, acknowledged, status, required, cohort, active, ticket, answers
vars == <<chosen, applied, acknowledged, status, required, cohort, active, ticket, answers>>
Init == /\ chosen = [s \in Slots |-> "empty"]
        /\ applied = [n \in Nodes |-> 0] /\ acknowledged = {}
        /\ status = [r \in Readers |-> "new"]
        /\ required = [r \in Readers |-> {}]
        /\ cohort = {} /\ active = FALSE /\ ticket = 0 /\ answers = {}
Visible(n) == {chosen[s] : s \in 1..applied[n]} \cap Writes
Write(s,w) == /\ chosen[s] = "empty" /\ \A t \in Slots : chosen[t] /= w
              /\ chosen' = [chosen EXCEPT ![s] = w]
              /\ UNCHANGED <<applied, acknowledged, status, required, cohort, active, ticket, answers>>
Skip(s) == /\ chosen[s] = "empty" /\ chosen' = [chosen EXCEPT ![s] = "skip"]
           /\ UNCHANGED <<applied, acknowledged, status, required, cohort, active, ticket, answers>>
Apply(n) == /\ applied[n] < 4 /\ chosen[applied[n]+1] /= "empty"
            /\ applied' = [applied EXCEPT ![n] = @+1]
            /\ UNCHANGED <<chosen, acknowledged, status, required, cohort, active, ticket, answers>>
Ack == /\ acknowledged' = acknowledged \cup Visible(1)
       /\ UNCHANGED <<chosen, applied, status, required, cohort, active, ticket, answers>>
Invoke(r) == /\ status[r] = "new" /\ status' = [status EXCEPT ![r] = "pending"]
             /\ required' = [required EXCEPT ![r] = acknowledged]
             /\ UNCHANGED <<chosen, applied, acknowledged, cohort, active, ticket, answers>>
Waiting == {r \in Readers : status[r] = "pending"}
Begin(s) == /\ ~active /\ Waiting /= {} /\ chosen[s] = "empty"
            /\ chosen' = [chosen EXCEPT ![s] = "read"]
            /\ cohort' = Waiting /\ active' = TRUE /\ ticket' = s
            /\ status' = [r \in Readers |-> IF r \in Waiting THEN "member" ELSE status[r]]
            /\ UNCHANGED <<applied, acknowledged, required, answers>>
LateJoin(r) == /\ ~CloseMembership /\ active /\ status[r] = "pending"
               /\ cohort' = cohort \cup {r} /\ status' = [status EXCEPT ![r] = "member"]
               /\ UNCHANGED <<chosen, applied, acknowledged, required, active, ticket, answers>>
Return(r) == /\ active /\ r \in cohort /\ (~AppliedGate \/ applied[2] >= ticket)
             /\ answers' = answers \cup {[need |-> required[r], seen |-> Visible(2),
                                          prefix |-> applied[2], fence |-> ticket]}
             /\ cohort' = cohort \ {r} /\ active' = (cohort \ {r} /= {})
             /\ status' = [status EXCEPT ![r] = "done"]
             /\ UNCHANGED <<chosen, applied, acknowledged, required, ticket>>
Cancel(r) == /\ status[r] \in {"pending","member"}
             /\ status' = [status EXCEPT ![r] = "cancelled"] /\ cohort' = cohort \ {r}
             /\ active' = IF r \in cohort /\ ~PreserveOtherWaiters THEN FALSE
                           ELSE (cohort \ {r} /= {})
             /\ UNCHANGED <<chosen, applied, acknowledged, required, ticket, answers>>
Next == (\E s \in Slots, w \in Writes : Write(s,w))
        \/ (\E s \in Slots : Skip(s) \/ Begin(s)) \/ (\E n \in Nodes : Apply(n)) \/ Ack
        \/ (\E r \in Readers : Invoke(r) \/ LateJoin(r) \/ Return(r) \/ Cancel(r))
Spec == Init /\ [][Next]_vars
RealTimeOrder == \A a \in answers : a.need \subseteq a.seen
AppliedBeforeSnapshot == \A a \in answers : a.prefix >= a.fence
MembersHaveBarrier == cohort /= {} => active
=============================================================================
