------------------------ MODULE GenerationCatalog ---------------------------
EXTENDS Naturals, FiniteSets, TLC
CONSTANTS GuardPublish, PreserveVote, PreservePromise, PreserveIDs
\* A quiesced local acceptor, not a proof of quorum agreement. Choice and receipt
\* validity are supplied by the consensus/certificate models. A generation keeps
\* its local suffix and a certified application prefix. FULL catalog commits are
\* atomic and durable. Torn/unknown files fail closed instead of selecting a past
\* generation. These are storage assumptions, not simulated physical power loss.
Generations == 0..2
VARIABLES current, stage, durable, images, suffixes, votes, promises, ids,
          acked, accepted, promised, reserved, ready, alive, source
vars == <<current, stage, durable, images, suffixes, votes, promises, ids,
          acked, accepted, promised, reserved, ready, alive, source>>
Init == /\ current = 0 /\ stage = 0 /\ durable = {0}
        /\ images = [g \in Generations |-> {}]
        /\ suffixes = [g \in Generations |-> {}]
        /\ votes = [g \in Generations |-> {}]
        /\ promises = [g \in Generations |-> 0]
        /\ ids = [g \in Generations |-> 0]
        /\ acked = {} /\ accepted = {} /\ promised = 0 /\ reserved = 0
        /\ ready = FALSE /\ alive = TRUE /\ source = 0
Write(n) == /\ alive /\ ~ready /\ stage = current /\ n \notin acked
            /\ acked' = acked \cup {n}
            /\ suffixes' = [suffixes EXCEPT ![current] = @ \cup {n}]
            /\ UNCHANGED <<current, stage, durable, images, votes, promises, ids,
                            accepted, promised, reserved, ready, alive, source>>
Accept == /\ alive /\ ~ready /\ stage = current /\ accepted = {}
          /\ accepted' = {3} /\ promised' = 2 /\ reserved' = 2
          /\ votes' = [votes EXCEPT ![current] = {3}]
          /\ promises' = [promises EXCEPT ![current] = 2]
          /\ ids' = [ids EXCEPT ![current] = 2]
          /\ UNCHANGED <<current, stage, durable, images, suffixes, acked, ready, alive, source>>
Stage == /\ alive /\ stage = current /\ current < 2
         /\ stage' = current + 1 /\ source' = current
         /\ images' = [images EXCEPT ![current+1] = acked \cap {1}]
         /\ suffixes' = [suffixes EXCEPT ![current+1] = acked \ {1}]
         /\ votes' = [votes EXCEPT ![current+1] = IF PreserveVote THEN accepted ELSE {}]
         /\ promises' = [promises EXCEPT ![current+1] = IF PreservePromise THEN promised ELSE 0]
         /\ ids' = [ids EXCEPT ![current+1] = IF PreserveIDs THEN reserved ELSE 0]
         /\ UNCHANGED <<current, durable, acked, accepted, promised, reserved, ready, alive>>
Sync == /\ alive /\ stage > current /\ durable' = durable \cup {stage} /\ ready' = TRUE
        /\ UNCHANGED <<current, stage, images, suffixes, votes, promises, ids,
                        acked, accepted, promised, reserved, alive, source>>
Publish == /\ alive /\ stage > current /\ (~GuardPublish \/ ready)
           /\ current' = stage /\ ready' = FALSE
           /\ UNCHANGED <<stage, durable, images, suffixes, votes, promises, ids,
                           acked, accepted, promised, reserved, alive, source>>
Crash == /\ alive /\ alive' = FALSE /\ ready' = FALSE /\ stage' = current
         /\ UNCHANGED <<current, durable, images, suffixes, votes, promises, ids,
                         acked, accepted, promised, reserved, source>>
Restart == /\ ~alive /\ alive' = TRUE
           /\ UNCHANGED <<current, stage, durable, images, suffixes, votes, promises, ids,
                           acked, accepted, promised, reserved, ready, source>>
Next == (\E n \in {1,2}: Write(n)) \/ Accept \/ Stage \/ Sync \/ Publish \/ Crash \/ Restart
Spec == Init /\ [][Next]_vars
PublishedDurable == current \in durable
AcknowledgedPrefix == acked \subseteq (images[current] \cup suffixes[current])
AcceptedSuffix == accepted \subseteq votes[current]
PromiseFence == promises[current] >= promised
RequestIDs == ids[current] >= reserved
RetainedPredecessor == source \in durable
=============================================================================
