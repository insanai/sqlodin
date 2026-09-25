------------------------ MODULE SnapshotPublication -------------------------
EXTENDS Naturals, FiniteSets
CONSTANT Guard
Nodes == {1,2,3}
VARIABLES images, certificate, seal, staged, published, trimmed
vars == <<images, certificate, seal, staged, published, trimmed>>
Init == /\ images = {} /\ certificate = FALSE /\ seal = FALSE
        /\ staged = FALSE /\ published = FALSE /\ trimmed = FALSE
Image(n) == /\ images' = images \cup {n}
            /\ UNCHANGED <<certificate, seal, staged, published, trimmed>>
Certify == /\ Cardinality(images) >= 2 /\ certificate' = TRUE
           /\ UNCHANGED <<images, seal, staged, published, trimmed>>
Seal == /\ certificate /\ seal' = TRUE
        /\ UNCHANGED <<images, certificate, staged, published, trimmed>>
Stage == /\ seal /\ staged' = TRUE
         /\ UNCHANGED <<images, certificate, seal, published, trimmed>>
Publish == /\ staged /\ published' = TRUE
           /\ UNCHANGED <<images, certificate, seal, staged, trimmed>>
Trim == /\ (~Guard \/ published) /\ trimmed' = TRUE
        /\ UNCHANGED <<images, certificate, seal, staged, published>>
Crash == /\ staged' = FALSE
         /\ UNCHANGED <<images, certificate, seal, published, trimmed>>
Next == (\E n \in Nodes : Image(n)) \/ Certify \/ Seal \/ Stage \/ Publish \/ Trim \/ Crash
Spec == Init /\ [][Next]_vars
Recoverable == trimmed => (published /\ seal /\ certificate /\ Cardinality(images) >= 2)
=============================================================================
