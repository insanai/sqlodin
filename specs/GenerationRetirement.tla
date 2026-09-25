---------------------- MODULE GenerationRetirement --------------------------
EXTENDS Naturals, FiniteSets, TLC
CONSTANTS GuardCurrent, GuardPrevious, GuardOwnership, GuardDirectorySync
Names == 1..3
UserFile == 4
VARIABLES current, previous, job, allocated, inventory, files, durableFiles,
          ready, cleaning, predecessor
vars == <<current, previous, job, allocated, inventory, files, durableFiles,
          ready, cleaning, predecessor>>
Init == /\ current = 0 /\ previous = 0 /\ job = 0
        /\ allocated = {} /\ inventory = {} /\ files = {0, UserFile}
        /\ durableFiles = files /\ ready = FALSE /\ cleaning = 0
        /\ predecessor = [g \in Names |-> 0]
Register(g) == /\ job = 0 /\ cleaning = 0 /\ g \in Names \ allocated
               /\ allocated' = allocated \cup {g}
               /\ inventory' = inventory \cup {g} /\ job' = g
               /\ predecessor' = [predecessor EXCEPT ![g] = current]
               /\ UNCHANGED <<current, previous, files, durableFiles, ready, cleaning>>
Create == /\ job # 0 /\ job \notin files
          /\ files' = files \cup {job}
          /\ UNCHANGED <<current, previous, job, allocated, inventory, durableFiles,
                          ready, cleaning, predecessor>>
SyncBuild == /\ job # 0 /\ job \in files /\ ~ready
             /\ durableFiles' = durableFiles \cup {job} /\ ready' = TRUE
             /\ UNCHANGED <<current, previous, job, allocated, inventory, files,
                             cleaning, predecessor>>
Publish == /\ job # 0 /\ ready
           /\ current' = job /\ previous' = predecessor[job]
           /\ job' = 0 /\ ready' = FALSE
           /\ UNCHANGED <<allocated, inventory, files, durableFiles, cleaning, predecessor>>
Retire(g) == /\ job = 0 /\ cleaning = 0
             /\ g \in (IF GuardOwnership THEN inventory ELSE inventory \cup {UserFile})
             /\ (~GuardCurrent \/ g # current)
             /\ (~GuardPrevious \/ g # previous)
             /\ cleaning' = g /\ files' = files \ {g}
             /\ UNCHANGED <<current, previous, job, allocated, inventory, durableFiles,
                             ready, predecessor>>
SyncRetire == /\ cleaning # 0
              /\ durableFiles' = durableFiles \ {cleaning}
              /\ UNCHANGED <<current, previous, job, allocated, inventory, files,
                              ready, cleaning, predecessor>>
Forget == /\ cleaning # 0 /\ (~GuardDirectorySync \/ cleaning \notin durableFiles)
          /\ inventory' = inventory \ {cleaning} /\ cleaning' = 0
          /\ UNCHANGED <<current, previous, job, allocated, files, durableFiles, ready, predecessor>>
Crash == /\ files' = durableFiles /\ cleaning' = 0 /\ job' = 0 /\ ready' = FALSE
         /\ UNCHANGED <<current, previous, allocated, inventory, durableFiles, predecessor>>
Next == (\E g \in Names: Register(g)) \/ Create \/ SyncBuild \/ Publish \/
        (\E g \in Names \cup {UserFile}: Retire(g)) \/ SyncRetire \/ Forget \/ Crash
Spec == Init /\ [][Next]_vars
CurrentRetained == current \in files /\ current \in durableFiles
PreviousRetained == previous \in files /\ previous \in durableFiles
UnownedUntouched == UserFile \in files /\ UserFile \in durableFiles
InventoryComplete == (durableFiles \ {0, UserFile}) \subseteq inventory
=============================================================================
