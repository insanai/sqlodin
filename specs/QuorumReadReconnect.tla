-------------------------- MODULE QuorumReadReconnect --------------------------
\* A completed write is durable at voters 3,4,5 before reader 1 invokes a read.
\* Voter 2 is stale. Reconnecting it must not manufacture a second quorum member.
\* This host-seam model keeps cohort identity separate from connection identity.
EXTENDS Naturals, FiniteSets
CONSTANT CountConnections
Peers == {2,3,4,5}
VARIABLES connectedReplies, voters, count, bound, answered, stale
vars == <<connectedReplies, voters, count, bound, answered, stale>>
Init == /\ connectedReplies = {} /\ voters = {} /\ count = 0 /\ bound = 0
        /\ answered = FALSE /\ stale = FALSE
Reply(p) == /\ ~answered /\ p \notin connectedReplies /\ count < 2
            /\ connectedReplies' = connectedReplies \cup {p}
            /\ voters' = voters \cup {p}
            /\ count' = IF CountConnections THEN count + 1 ELSE Cardinality(voters')
            /\ bound' = IF p \in {3,4,5} THEN 1 ELSE bound
            /\ UNCHANGED <<answered, stale>>
Reconnect(p) == /\ connectedReplies' = connectedReplies \ {p}
                /\ UNCHANGED <<voters, count, bound, answered, stale>>
\* A reader with bound 1 must recover the write before answering. Bound 0
\* permits a stale snapshot if connection replies have falsely formed a quorum.
Answer == /\ ~answered /\ count >= 2
          /\ answered' = TRUE /\ stale' = (bound = 0)
          /\ UNCHANGED <<connectedReplies, voters, count, bound>>
Next == (\E p \in Peers : Reply(p) \/ Reconnect(p)) \/ Answer
Spec == Init /\ [][Next]_vars
RealTimeOrder == ~stale
=============================================================================
