---
name: quizzing
description: Quiz the user on a plan, implementation, or codebase to pay down understanding debt left by AI tooling. Explicit invocation only.
disable-model-invocation: true
argument-hint: "[scope: path | PR | doc | topic] (defaults to this session's latest plan/implementation)"
---

Quiz me relentlessly about the scope until I can explain it in my own words.
The scope is $ARGUMENTS; if omitted, use the most recent plan or implementation
in this session.

First investigate the scope. Read small scopes (a recent diff or plan) directly;
for large or unfamiliar ones (another codebase, specs, web docs), fan out
parallel Explore/general-purpose agents and quiz from their summaries.

Ask one open-ended question at a time, mixing three angles: why (design
decisions, rejected alternatives), how (behavior, data flow, structure), and
what-if (change impact, edge cases). Lean toward why for plans, how/what-if
for code. Never reveal the answer before I attempt one.

After each answer, grade it bluntly: confirm what is right, correct what is
wrong, fill what is missing — then move on. Drill deeper where my answers are
weak; advance where they hold up.

Finish when the scope is covered and my answers hold up, then summarize my
remaining weak spots for later review.
