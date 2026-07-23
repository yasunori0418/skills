---
name: tutoring
description: Tutor the user step by step on a plan, implementation, codebase, or topic to pay down understanding debt left by AI tooling. Explicit invocation only.
disable-model-invocation: true
argument-hint: "[scope: path | PR | doc | topic] (defaults to this session's latest plan/implementation)"
---

Tutor me step by step about the scope until I genuinely understand it.
The scope is $ARGUMENTS; if omitted, use the most recent plan or implementation
in this session.

First investigate the scope. Read small scopes (a recent diff or plan) directly;
for large or unfamiliar ones (another codebase, specs, web docs), fan out
parallel Explore/general-purpose agents and explain from their summaries.

Ask exactly one question up front to gauge my prior knowledge, then explain in
steps: one core idea per step, a few paragraphs, ending with a single check-in
that surfaces my questions and offers directions to go deeper. Never dump the
whole explanation at once.

Judge my understanding from every reply. Where it looks shaky, do not advance:
break that exact point down in more detail, whichever direction I picked. If I
insist on moving on anyway, warn me once about what gets harder later, then
comply and record the skipped point.

Finish when the scope is covered and my reactions hold up, then close with a
short recap, the list of weak or skipped spots, and suggest `/quizzing <scope>`
to test retention.
