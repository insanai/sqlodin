-------------------------- MODULE SessionRetirement --------------------------
EXTENDS Naturals, FiniteSets, TLC
CONSTANTS AllowOld, LoseEpochOnCrash, RetireAny, KeepRetiredRows
Epochs == 0..2
Sessions == 1..2
Requests == Epochs \X Sessions
VARIABLES epoch, rows, effects, advances
vars == <<epoch, rows, effects, advances>>
Init == /\ epoch = 0
        /\ rows = {}
        /\ effects = [r \in Requests |-> 0]
        /\ advances = [e \in Epochs |-> 0]
Execute(r) ==
    /\ (r[1] = epoch \/ AllowOld)
    /\ r \notin rows
    /\ Cardinality(rows) < 2
    /\ effects[r] < 2
    /\ effects' = [effects EXCEPT ![r] = @ + 1]
    /\ rows' = rows \cup {r}
    /\ UNCHANGED <<epoch, advances>>
Retire(expected) ==
    /\ epoch < 2
    /\ (expected = epoch \/ RetireAny)
    /\ epoch' = epoch + 1
    /\ rows' = IF KeepRetiredRows THEN rows ELSE {}
    /\ advances' = [advances EXCEPT ![expected] = @ + 1]
    /\ UNCHANGED effects
Crash == /\ epoch' = IF LoseEpochOnCrash THEN 0 ELSE epoch
         /\ UNCHANGED <<rows, effects, advances>>
Next == (\E r \in Requests : Execute(r)) \/ (\E e \in Epochs : Retire(e)) \/ Crash
Spec == Init /\ [][Next]_vars
TypeOK == /\ epoch \in Epochs /\ rows \subseteq Requests
          /\ effects \in [Requests -> 0..2] /\ advances \in [Epochs -> 0..2]
AtMostOnce == \A r \in Requests : effects[r] <= 1
CommandIdempotent == \A e \in Epochs : advances[e] <= 1
OnlyCurrentRows == \A r \in rows : r[1] = epoch
BoundedRows == Cardinality(rows) <= 2
=============================================================================
