------------------------- MODULE ManifestDurability -------------------------
EXTENDS Naturals
CONSTANTS SyncFile, SyncDirectory
VARIABLES volatileFile, stableFile, visibleName, stableName, done, phase
vars == <<volatileFile, stableFile, visibleName, stableName, done, phase>>
Init == /\ volatileFile = "absent" /\ stableFile = "absent"
        /\ visibleName = FALSE /\ stableName = FALSE /\ done = FALSE /\ phase = 0
Create == /\ phase = 0 /\ visibleName' = TRUE /\ volatileFile' = "partial"
          /\ phase' = 1 /\ UNCHANGED <<stableFile, stableName, done>>
Write == /\ phase = 1 /\ volatileFile' = "complete" /\ phase' = 2
         /\ UNCHANGED <<stableFile, visibleName, stableName, done>>
FileBarrier == /\ phase = 2 /\ phase' = 3
               /\ stableFile' = IF SyncFile THEN volatileFile ELSE stableFile
               /\ UNCHANGED <<volatileFile, visibleName, stableName, done>>
DirectoryBarrier == /\ phase = 3 /\ phase' = 4
                    /\ stableName' = IF SyncDirectory THEN visibleName ELSE stableName
                    /\ UNCHANGED <<volatileFile, stableFile, visibleName, done>>
Return == /\ phase = 4 /\ done' = TRUE /\ phase' = 5
          /\ UNCHANGED <<volatileFile, stableFile, visibleName, stableName>>
Crash == /\ phase < 6 /\ volatileFile' = stableFile /\ visibleName' = stableName
         /\ phase' = 6 /\ UNCHANGED <<stableFile, stableName, done>>
Next == Create \/ Write \/ FileBarrier \/ DirectoryBarrier \/ Return \/ Crash
Spec == Init /\ [][Next]_vars
SuccessSurvives == done => (stableFile = "complete" /\ stableName)
=============================================================================
