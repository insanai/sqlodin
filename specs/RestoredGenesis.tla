------------------------ MODULE RestoredGenesis -----------------------------
EXTENDS Naturals, FiniteSets, TLC
CONSTANTS GuardNamespace, GuardImage, GuardDurability, PreservePrefix
Nodes == 1..2
Backups == 1..2
BackupPrefix(b) == IF b = 1 THEN 0 ELSE 3
SessionSlot(b) == IF b = 1 THEN 0 ELSE 2
VARIABLES phase, image, namespace, prefix, synced, connected
vars == <<phase, image, namespace, prefix, synced, connected>>
Init == /\ phase = [n \in Nodes |-> 0] /\ image = [n \in Nodes |-> 1]
        /\ namespace = [n \in Nodes |-> 0] /\ prefix = [n \in Nodes |-> 0]
        /\ synced = {} /\ connected = FALSE
Stage(n,b,k) == /\ phase[n] = 0 /\ (~GuardNamespace \/ k # 0)
                 /\ phase' = [phase EXCEPT ![n] = 1]
                 /\ image' = [image EXCEPT ![n] = b]
                 /\ namespace' = [namespace EXCEPT ![n] = k]
                 /\ prefix' = [prefix EXCEPT ![n] = IF PreservePrefix THEN BackupPrefix(b) ELSE 0]
                 /\ UNCHANGED <<synced, connected>>
Sync(n) == /\ phase[n] = 1 /\ synced' = synced \cup {n}
           /\ phase' = [phase EXCEPT ![n] = 2]
           /\ UNCHANGED <<image, namespace, prefix, connected>>
Publish(n) == /\ phase[n] \in {1,2} /\ (~GuardDurability \/ n \in synced)
              /\ phase' = [phase EXCEPT ![n] = 3]
              /\ UNCHANGED <<image, namespace, prefix, synced, connected>>
Connect == /\ ~connected /\ phase[1] = 3 /\ phase[2] = 3
           /\ namespace[1] = namespace[2] /\ (~GuardImage \/ image[1] = image[2])
           /\ connected' = TRUE /\ UNCHANGED <<phase, image, namespace, prefix, synced>>
Next == (\E n \in Nodes, b \in Backups, k \in 0..1: Stage(n,b,k)) \/
        (\E n \in Nodes: Sync(n) \/ Publish(n)) \/ Connect
Spec == Init /\ [][Next]_vars
FreshNamespace == \A n \in Nodes: phase[n] = 3 => namespace[n] # 0
ReadyDurable == \A n \in Nodes: phase[n] = 3 => n \in synced
RetryOriginsValid == \A n \in Nodes: phase[n] = 3 => SessionSlot(image[n]) <= prefix[n]
CompatibleInitialState == connected => image[1] = image[2] /\ prefix[1] = prefix[2]
=============================================================================
