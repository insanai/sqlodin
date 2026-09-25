------------------------- MODULE PrefixRecoveryProof -------------------------
EXTENDS Integers, TLAPS
\* Unbounded-slot composition lemma. Each chosen slot denotes its one immutable
\* SQL transition (agreement and determinism are assumptions supplied elsewhere).
\* cut denotes a durably published certified image of exactly that prefix.
VARIABLES chosen, tail, committed, applied, cut, acknowledged, ready
vars == <<chosen, tail, committed, applied, cut, acknowledged, ready>>
Init == /\ chosen = {} /\ tail = {} /\ committed = 0 /\ applied = 0
        /\ cut = 0 /\ acknowledged = 0 /\ ready = TRUE
Choose(s) == /\ s \in Nat \ {0} /\ chosen' = chosen \cup {s}
             /\ UNCHANGED <<tail, committed, applied, cut, acknowledged, ready>>
Apply == /\ ready /\ committed+1 \in chosen
         /\ committed' = committed+1 /\ applied' = applied+1
         /\ tail' = tail \cup {committed+1}
         /\ UNCHANGED <<chosen, cut, acknowledged, ready>>
Ack == /\ ready /\ acknowledged' = committed
       /\ UNCHANGED <<chosen, tail, committed, applied, cut, ready>>
Publish(k) == /\ ready /\ k \in cut..committed /\ cut' = k
              /\ UNCHANGED <<chosen, tail, committed, applied, acknowledged, ready>>
Trim == /\ tail' = tail \ (1..cut)
        /\ UNCHANGED <<chosen, committed, applied, cut, acknowledged, ready>>
Crash == /\ ready' = FALSE /\ applied' = cut
         /\ UNCHANGED <<chosen, tail, committed, cut, acknowledged>>
Replay == /\ ~ready /\ applied < committed /\ applied+1 \in tail
          /\ applied' = applied+1
          /\ UNCHANGED <<chosen, tail, committed, cut, acknowledged, ready>>
Open == /\ ~ready /\ applied = committed /\ ready' = TRUE
        /\ UNCHANGED <<chosen, tail, committed, applied, cut, acknowledged>>
Next == (\E s \in Nat : Choose(s)) \/ Apply \/ Ack \/ Trim \/ Crash \/ Replay \/ Open
        \/ (\E k \in Nat : Publish(k))
Spec == Init /\ [][Next]_vars
Inv == /\ chosen \subseteq Nat \ {0} /\ tail \subseteq chosen
       /\ committed \in Nat /\ cut \in 0..applied /\ applied \in 0..committed
       /\ acknowledged \in 0..committed /\ ready \in BOOLEAN
       /\ (1..committed) \subseteq chosen
       /\ ((cut+1)..committed) \subseteq tail
       /\ (ready => applied = committed)

THEOREM InitialPrefix == Init => Inv
BY SMT DEF Init, Inv

THEOREM ChoosePrefix == \A s \in Nat : Inv /\ Choose(s) => Inv'
BY SMT DEF Inv, Choose

THEOREM ApplyPrefix == Inv /\ Apply => Inv'
BY SMT DEF Inv, Apply

THEOREM AckPrefix == Inv /\ Ack => Inv'
BY SMT DEF Inv, Ack

THEOREM PublishPrefix == \A k \in Nat : Inv /\ Publish(k) => Inv'
BY SMT DEF Inv, Publish

THEOREM TrimPrefix == Inv /\ Trim => Inv'
BY SMT DEF Inv, Trim

THEOREM CrashPrefix == Inv /\ Crash => Inv'
BY SMT DEF Inv, Crash

THEOREM ReplayPrefix == Inv /\ Replay => Inv'
BY SMT DEF Inv, Replay

THEOREM OpenPrefix == Inv /\ Open => Inv'
BY SMT DEF Inv, Open

THEOREM PreservePrefix == Inv /\ [Next]_vars => Inv'
BY ChoosePrefix, ApplyPrefix, AckPrefix, PublishPrefix, TrimPrefix, CrashPrefix,
   ReplayPrefix, OpenPrefix, SMT DEF Inv, Next, vars

THEOREM PrefixRecoverySafety == Spec => []Inv
<1>1. Init => Inv
  BY InitialPrefix
<1>2. Inv /\ [Next]_vars => Inv'
  BY PreservePrefix
<1> QED BY <1>1, <1>2, PTL DEF Spec
=============================================================================
