--------------------------- MODULE DurableEffects ---------------------------
EXTENDS Naturals, FiniteSets
CONSTANT Gate
Nodes == {1,2,3}
VARIABLES staged, durable, sent, chosen, applied, ack
vars == <<staged, durable, sent, chosen, applied, ack>>
Init == /\ staged = {} /\ durable = {} /\ sent = {}
        /\ chosen = FALSE /\ applied = FALSE /\ ack = FALSE
Stage(n) == /\ n \notin staged /\ staged' = staged \cup {n}
            /\ UNCHANGED <<durable, sent, chosen, applied, ack>>
Sync(n) == /\ n \in staged /\ durable' = durable \cup {n}
           /\ UNCHANGED <<staged, sent, chosen, applied, ack>>
Send(n) == /\ n \in staged /\ (~Gate \/ n \in durable)
           /\ sent' = sent \cup {n}
           /\ UNCHANGED <<staged, durable, chosen, applied, ack>>
Crash(n) == /\ staged' = staged \ {n}
            /\ UNCHANGED <<durable, sent, chosen, applied, ack>>
Choose == /\ Cardinality(sent) >= 2 /\ chosen' = TRUE
          /\ UNCHANGED <<staged, durable, sent, applied, ack>>
Apply == /\ chosen /\ applied' = TRUE
         /\ UNCHANGED <<staged, durable, sent, chosen, ack>>
Ack == /\ applied /\ ack' = TRUE
       /\ UNCHANGED <<staged, durable, sent, chosen, applied>>
Next == (\E n \in Nodes : Stage(n) \/ Sync(n) \/ Send(n) \/ Crash(n))
        \/ Choose \/ Apply \/ Ack
Spec == Init /\ [][Next]_vars
DurableBeforeSend == sent \subseteq durable
AckSurvives == ack => (applied /\ chosen /\ Cardinality(durable) >= 2)
=============================================================================
