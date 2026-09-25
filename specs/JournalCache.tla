----------------------------- MODULE JournalCache -----------------------------
\* SOD 0005 M4: a separated application database committed without a sync
\* barrier, recovered from the FULL journal. Slots 1..K are decided in order.
\* journal: durable decision records. staged: records in the open journal
\* transaction. mem/disk: applied prefix in the page cache / on stable storage.
\* base: the FULL-synchronized certified image prefix of the active generation.
EXTENDS Naturals, FiniteSets
CONSTANTS K, ApplyStaged, TrimWithoutImage
Slots == 1..K
VARIABLES journal, staged, mem, disk, base, acked
vars == <<journal, staged, mem, disk, base, acked>>
Top(S) == IF S = {} THEN 0 ELSE CHOOSE s \in S : \A t \in S : t <= s
Init == /\ journal = {} /\ staged = {} /\ mem = 0 /\ disk = 0 /\ base = 0 /\ acked = {}
\* A turn stages the next decision record, then commits it with one barrier.
Stage == /\ Top(journal \cup staged) < K /\ staged' = staged \cup {Top(journal \cup staged) + 1}
         /\ UNCHANGED <<journal, mem, disk, base, acked>>
Commit == /\ staged /= {} /\ journal' = journal \cup staged /\ staged' = {}
          /\ UNCHANGED <<mem, disk, base, acked>>
\* J1: apply only committed decisions. ApplyStaged is the negative control.
Apply == /\ mem < K /\ mem + 1 \in (IF ApplyStaged THEN journal \cup staged ELSE journal)
         /\ mem' = mem + 1 /\ UNCHANGED <<journal, staged, disk, base, acked>>
Ack == /\ \E s \in 1..mem : acked' = acked \cup {s}
       /\ UNCHANGED <<journal, staged, mem, disk, base>>
\* The kernel may write back any prefix of committed WAL frames at any time;
\* a checkpoint is the same transition with k = mem.
Flush == /\ \E k \in (disk+1)..mem : disk' = k
         /\ UNCHANGED <<journal, staged, mem, base, acked>>
\* Publish a generation at b: the image of prefix b is FULL-synchronized and
\* decisions <= b leave the journal (J2). TrimWithoutImage drops them while
\* the application still depends on the unsynchronized tail.
Compact == /\ \E b \in (base+1)..mem :
                /\ base' = b
                /\ journal' = {s \in journal : s > b}
                /\ disk' = IF TrimWithoutImage THEN disk ELSE (IF disk < b THEN b ELSE disk)
           /\ UNCHANGED <<staged, mem, acked>>
\* Power loss: the open transaction and every unflushed application frame are
\* lost. Recovery replays the contiguous durable journal above the disk prefix.
Replayable(d) == LET R == {n \in d..K : \A t \in (d+1)..n : t \in journal} IN Top(R)
Crash == /\ staged' = {}
         /\ mem' = Replayable(disk)
         /\ disk' = disk
         /\ UNCHANGED <<journal, base, acked>>
Next == Stage \/ Commit \/ Apply \/ Ack \/ Flush \/ Compact \/ Crash
Spec == Init /\ [][Next]_vars
\* recover_application refuses a durable applied slot without decision evidence.
DiskHasEvidence == \A s \in (base+1)..disk : s \in journal
\* Every acknowledged outcome is reproduced by recovery.
AckedRecoverable == \A s \in acked : s <= Replayable(disk)
ImageBelowDisk == base <= disk
=============================================================================
