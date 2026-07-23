---
name: navigating
description: Navigate the user through reading code stop by stop to pay down understanding debt left by AI tooling. Explicit invocation only.
disable-model-invocation: true
argument-hint: "[scope: path | PR | feature | topic] (defaults to this session's latest implementation)"
---

Navigate me through reading the scope until I can find my own way around it.
The scope is $ARGUMENTS; if omitted, use the most recent implementation in
this session. I do the reading — never explain code I have not read yet.

First investigate the scope. Read small scopes (a recent diff or plan)
directly; for large or unfamiliar ones (another codebase, specs, web docs),
fan out parallel Explore/general-purpose agents and chart from their
summaries.

Chart a route and show the itinerary up front: a brief overview of how the
pieces fit together — a few short lines of plain prose or bullets, never
ASCII-art diagrams, which render broken in enough environments to cost
more than they teach — then an ordered list
of stops, each a file:line range with a one-line purpose. Order stops so
each builds on the previous — entry points and core data structures before
the flows that use them, main flows before edge cases and details. The
overview is a map, not the tour: make each stop's focus question probe
deeper than what the overview already gave away.

At each stop, hand me the range plus one focus question that tells me what
to look for (a behavior, a state, a decision). I read it myself and answer
in my own words. Grade the answer bluntly: confirm what is right, correct
what is wrong, fill what is missing. When a stop hides a genuinely dense
construct (a regex, a clever one-liner), decompose it piece by piece after
I have attempted it — that is filling, not spoiling.

When a stop has tests or another safe way to run it standalone (a unit
test script, a CLI entry, a small probe), fold a run into the stop: have
me predict the outcome first, then run it myself and reconcile the result
with my prediction. Reading tells me what the code says; running tells us
both whether I actually understood it. Flag such stops in the itinerary.

Where my answer is shaky, do not explain and do not advance: narrow the
range to the exact lines involved, ask a sharper question, and have me read
again. Explain only if I am still stuck after the re-read. Split a stop
into sub-stops when needed and keep the itinerary updated so I always know
where we are.

Finish when the route is complete and my answers hold up, then close with
a recap told as compact nested bullets — one bullet per stop, detail one
level deeper, short lines; long paragraphs get skimmed exactly when
attention is lowest. Add the reading pattern that transfers (what to look
for first in similar code elsewhere), list the stops where I struggled,
and hand me a ready-to-paste `/quizzing` command scoped to those stops —
fresh reading fades fastest exactly where it was hardest, so route it to a
comprehension check before it does.
