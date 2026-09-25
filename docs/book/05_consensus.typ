#import "theme.typ": callout
#import "figures.typ": panel, steps
= Quorum agreement and progress
<consensus>

A voter can crash after sending a reply. A message can arrive twice or arrive late.
Paxos must preserve a chosen value through these events. The key is not that every
voter always agrees; it is that a later successful proposer cannot choose a different
value for the same slot.

== The intersection fact

For $N$ voters, a majority has size $q = floor(N/2)+1$. Any two majority sets $Q_1$
and $Q_2$ satisfy

$ |Q_1 inter Q_2| >= 2q - N > 0. $

The inequality follows because their union contains at most $N$ voters. For three
voters, every quorum has two members. Any pair of such quorums shares at least one.

#figure(grid(columns: 3, gutter: 8pt,
  panel([Quorum A], [Voters 1 and 2]),
  panel([Intersection], [Voter 2]),
  panel([Quorum B], [Voters 2 and 3])),
  caption: [The shared voter carries evidence from an earlier choice into a later recovery.])

Intersection alone is insufficient. The shared voter must retain its promise and
accepted vote across a crash. It must also report that evidence during recovery.

== Promises, votes and ballots

A ballot orders competing attempts. A proposer uses a unique higher ballot to recover
a slot. An acceptor promises not to accept lower ballots and reports its accepted
value and ballot, if any. Both promise and vote are durable facts.

#table(columns: (1fr, 2fr),
  table.header([Phase], [Rule]),
  [Prepare], [Obtain a majority of promises for the new ballot.],
  [Select], [If replies contain votes, use the value at the highest accepted ballot. Otherwise choose a value.],
  [Accept], [Obtain a majority of durable votes for that ballot and value.],
  [Learn], [Disseminate the chosen value; apply it only in prefix order.],
)

A ballot must not propose two different values for one slot. An acceptor rejects
conflicting values at one ballot and values below its applicable promise. The unique
slot owner may use round zero; acceptors check this ownership rule. Round zero is
not permission for another voter to skip recovery.

== The agreement argument

Assume value $v$ was chosen by quorum $Q$ at ballot $b$. Consider a later successful
prepare quorum $Q'$. It intersects $Q$. At least one reply therefore contains a vote
for $v$ or a later accepted vote.

Why must that later vote also name $v$? Induct over higher ballots. The first higher
proposer that could obtain a quorum must carry forward the earlier accepted value.
At each subsequent successful ballot, highest-vote selection carries the same value
forward. A lower ballot cannot collect a new conflicting quorum after the higher
promises: the quorums intersect again. Thus two chosen values for one slot must be equal.

This is an argument about protocol actions under durable, truthful acceptors. It does
not prove that arbitrary code implements those actions. The model and implementation
checks in @proofs test that correspondence. Byzantine voters, lost durable identities
and a device that reports a false successful synchronization violate the premises.

== Progress is a different claim

Safety says conflicting choices do not occur. Progress says pending work eventually
finishes. A network that drops every message can preserve safety forever while doing
no useful work. SQLodin needs a surviving majority, eventual successful communication,
fair scheduling and storage/application work that eventually completes.

For a finite offered frontier $h$, consider the lowest unapplied slot $s <= h$:

+ A live owner proposes work or fills a required gap with a skip.
+ If the owner is absent, a surviving voter recovers the slot at a higher ballot.
+ Under an eventually non-preempted exchange, a majority chooses a value.
+ Learning and application advance the contiguous prefix.

The distance $h-a$ decreases as applied prefix $a$ advances. Repeating the argument
reaches $h$. New arrivals create new frontiers; the argument does not promise an
individual request freedom from starvation under perpetual interference or overload.

Healthy gap filling is event-driven. A regression advances the prefix with no timer
ticks, guarding against the earlier 100 ms slot-selection delay. Missing-owner recovery
still uses a failure detector: the default stall interval is ten 100 ms ticks. A timer
is evidence that recovery should be attempted, not proof that a voter has failed.

#callout(title: "One voter down")[
With three voters, either survivor can admit a write when the two survivors communicate
and make durable progress. One isolated voter cannot acknowledge a new write or a fresh
quorum read. Multi-master does not mean each voter can commit alone.
]

See #link("../../specs/multimaster-refinement.typ")[the composition argument] for the
mapping to upstream ownership, revocation, promise and acceptor functions.
