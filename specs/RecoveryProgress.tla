-------------------------- MODULE RecoveryProgress --------------------------
EXTENDS Naturals, FiniteSets
CONSTANTS Target, Chunk, Probe, Continue, LoseFirst
VARIABLES applied, known, request, response, dropped
vars == <<applied, known, request, response, dropped>>
Init == /\ applied = 0 /\ known = 0 /\ request = FALSE
        /\ response = 0 /\ dropped = FALSE
\* A live peer advertises a stable target; it is not a chosen-value proof.
\* The concrete host must authenticate that peer and validate every decision.
Discover == /\ Probe /\ known < Target /\ known' = Target
            /\ UNCHANGED <<applied, request, response, dropped>>
Request == /\ applied < known /\ ~request /\ response = 0
           /\ (Continue \/ applied = 0)
           /\ request' = TRUE
           /\ UNCHANGED <<applied, known, response, dropped>>
Drop == /\ LoseFirst /\ ~dropped /\ request
        /\ dropped' = TRUE /\ request' = FALSE
        /\ UNCHANGED <<applied, known, response>>
Serve == /\ request /\ (~LoseFirst \/ dropped)
         /\ response' = IF applied + Chunk < known THEN applied + Chunk ELSE known
         /\ request' = FALSE
         /\ UNCHANGED <<applied, known, dropped>>
Apply == /\ response > applied /\ applied' = response /\ response' = 0
         /\ UNCHANGED <<known, request, dropped>>
Next == Discover \/ Request \/ Drop \/ Serve \/ Apply
Spec == Init /\ [][Next]_vars /\ WF_vars(Discover) /\ WF_vars(Request)
        /\ WF_vars(Drop) /\ WF_vars(Serve) /\ WF_vars(Apply)
TypeOK == /\ applied \in 0..Target /\ known \in 0..Target
          /\ response \in 0..Target /\ request \in BOOLEAN /\ dropped \in BOOLEAN
PrefixBound == applied <= known
Converges == <> (applied = Target)
=============================================================================
