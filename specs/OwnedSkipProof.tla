-------------------------- MODULE OwnedSkipProof --------------------------
\* SOD 0005 M2, unbounded ballots and values. Round 0 of an owned slot has a
\* single durable owner offer. A revoker (round b > 0) offers the no-op or the
\* value of some reported durable vote; this is weaker than B3's highest vote,
\* so the lemma also covers the implementation. Quorum detail is abstracted:
\* a chosen value is the value of a voted offer. The lemma: once the owner's
\* round-0 offer is the no-op, every offer is the no-op, so fast learning of
\* that no-op can never disagree with a decision.
EXTENDS Naturals, TLAPS
CONSTANTS Values, Noop
ASSUME NoopValue == Noop \in Values
VARIABLES offers, votes, reports, chosen, learned
vars == <<offers, votes, reports, chosen, learned>>
Init == offers = {} /\ votes = {} /\ reports = {} /\ chosen = {} /\ learned = {}
Own(v) == /\ v \in Values /\ \A o \in offers : o[1] /= 0
          /\ offers' = offers \cup {<<0, v>>} /\ votes' = votes \cup {<<0, v>>}
          /\ UNCHANGED <<reports, chosen, learned>>
Vote(o) == /\ o \in offers /\ votes' = votes \cup {o}
           /\ UNCHANGED <<offers, reports, chosen, learned>>
Report(b, x) == /\ b \in Nat /\ x \in votes /\ reports' = reports \cup {<<b, x>>}
                /\ UNCHANGED <<offers, votes, chosen, learned>>
Offer(b, v) == /\ b \in Nat /\ b /= 0 /\ v \in Values /\ \A o \in offers : o[1] /= b
               /\ \/ v = Noop
                  \/ \E r \in reports : r[1] = b /\ r[2][2] = v
               /\ offers' = offers \cup {<<b, v>>}
               /\ UNCHANGED <<votes, reports, chosen, learned>>
Choose(o) == /\ o \in votes /\ chosen' = chosen \cup {o[2]}
             /\ UNCHANGED <<offers, votes, reports, learned>>
FastLearn == /\ <<0, Noop>> \in offers /\ learned' = learned \cup {Noop}
             /\ UNCHANGED <<offers, votes, reports, chosen>>
Next == \/ \E v \in Values : Own(v)
        \/ \E o \in offers : Vote(o)
        \/ \E b \in Nat, x \in votes : Report(b, x)
        \/ \E b \in Nat, v \in Values : Offer(b, v)
        \/ \E o \in votes : Choose(o)
        \/ FastLearn
Spec == Init /\ [][Next]_vars

OwnerOnlyNoop == \A o \in offers : o[1] = 0 => o[2] = Noop
Inv == /\ votes \subseteq offers
       /\ \A r \in reports : r[2] \in votes
       /\ \A v \in chosen : \E o \in votes : o[2] = v
       /\ OwnerOnlyNoop => \A o \in offers : o[2] = Noop
       /\ learned \subseteq {Noop}
       /\ learned /= {} => <<0, Noop>> \in offers
       /\ \A o1, o2 \in offers : o1[1] = 0 /\ o2[1] = 0 => o1 = o2

FastLearnSafe == Noop \in learned => chosen \subseteq {Noop}

THEOREM InitialInvariant == Init => Inv
BY DEF Init, Inv, OwnerOnlyNoop

THEOREM PreserveInvariant == Inv /\ [Next]_vars => Inv'
<1> SUFFICES ASSUME Inv, [Next]_vars PROVE Inv'
  OBVIOUS
<1>1. CASE \E v \in Values : Own(v)
  BY <1>1 DEF Inv, Own, OwnerOnlyNoop
<1>2. CASE \E o \in offers : Vote(o)
  BY <1>2 DEF Inv, Vote, OwnerOnlyNoop
<1>3. CASE \E b \in Nat, x \in votes : Report(b, x)
  BY <1>3 DEF Inv, Report, OwnerOnlyNoop
<1>4. CASE \E b \in Nat, v \in Values : Offer(b, v)
  <2> PICK b \in Nat, v \in Values : Offer(b, v)
    BY <1>4
  <2>1. OwnerOnlyNoop' => OwnerOnlyNoop
    BY DEF Offer, OwnerOnlyNoop
  <2>2. OwnerOnlyNoop => v = Noop
    BY DEF Inv, Offer, OwnerOnlyNoop
  <2> QED
    BY <2>1, <2>2 DEF Inv, Offer, OwnerOnlyNoop
<1>5. CASE \E o \in votes : Choose(o)
  BY <1>5 DEF Inv, Choose, OwnerOnlyNoop
<1>6. CASE FastLearn
  BY <1>6 DEF Inv, FastLearn, OwnerOnlyNoop
<1>7. CASE UNCHANGED vars
  BY <1>7 DEF Inv, vars, OwnerOnlyNoop
<1> QED
  BY <1>1, <1>2, <1>3, <1>4, <1>5, <1>6, <1>7 DEF Next

THEOREM InvImpliesFastLearnSafe == Inv => FastLearnSafe
BY DEF Inv, FastLearnSafe, OwnerOnlyNoop

THEOREM OwnedSkipSafety == Spec => [](Inv /\ FastLearnSafe)
<1>1. Init => Inv
  BY InitialInvariant
<1>2. Inv /\ [Next]_vars => Inv'
  BY PreserveInvariant
<1>3. Inv => FastLearnSafe
  BY InvImpliesFastLearnSafe
<1> QED BY <1>1, <1>2, <1>3, PTL DEF Spec
=============================================================================
