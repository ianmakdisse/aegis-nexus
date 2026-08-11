# Architecture Principles

> **Principles vs. the Constitution.** The [Constitution](architecture-constitution.md) is *law* — violating an
> invariant fails the build. These principles are *guidance* — they resolve judgment calls where the law is
> silent. When a principle and an invariant conflict, the invariant wins.
>
> Each principle states the trade-off it accepts. A principle with no cost is a slogan.

---

## P1 — Make the correct thing the easy thing

Correctness that depends on remembering is correctness that will lapse. Where a rule matters, encode it in a
type signature, a required argument, a base class, or a lint rule.

**In practice:** `VectorStore#search` requires a `tenant:` argument. `Events::Publisher` raises outside a
transaction. `Consumer` refuses a handler with no dedup key. None of these are documentation.

**Cost accepted:** more scaffolding, and occasional friction when the guardrail is genuinely not needed.

## P2 — Fail closed on authority, fail open on convenience

Anything that grants access, permits spend, or asserts identity denies on ambiguity. Anything that merely makes
things faster or prettier degrades quietly.

**In practice:** missing tenant context → raise. Authorization evaluator unavailable → deny. Redis down →
serve from the database and keep going.

**Cost accepted:** availability incidents caused by our own strictness. We prefer them to silent authorization gaps.

## P3 — Prefer boring technology for load-bearing components

Novelty budget is finite. Spend it on the product's genuine differentiators (durable workflow semantics, agent
governance), not on infrastructure whose failure modes nobody on the team has seen at 3 a.m.

**In practice:** PostgreSQL for nearly everything ([ADR-002](../11-decisions/ADR-002-database.md)); pgvector
before a dedicated vector database ([ADR-008](../11-decisions/ADR-008-vector-database.md)).

**Cost accepted:** we will hit ceilings that a specialized tool would not have. The exit criteria in those ADRs
are how we make that a decision instead of a surprise.

## P4 — Add complexity on evidence, not anticipation

Every "we'll need this at scale" component is a bet paid for immediately and settled maybe never. Pre-commit
the *measurement* that would justify it.

**In practice:** the threshold tables in ADR-002 and ADR-008; the migration triggers in ADR-006.

**Cost accepted:** occasionally we will add a component later, under pressure, that would have been calmer to
add early. The thresholds exist to make "later" arrive before "under pressure" does.

## P5 — Design for the failure, then the feature

The failure path is the product for an operations platform. A feature whose failure behavior is undefined is
not finished.

**In practice:** [failure-domains.md](failure-domains.md) is populated when a component is designed, not after
its first incident. Every synchronous dependency in the [context map](context-map.md) declares its degradation.

**Cost accepted:** slower initial delivery per feature.

## P6 — Make the boundary the contract

Modules communicate through published contracts; everything else is private. This is what preserves the option
to change internals — and to extract a service — without coordination.

**In practice:** `internal/` is enforced, not conventional. See [context map](context-map.md).

**Cost accepted:** occasional indirection where a direct query would have been two lines.

## P7 — Treat AI output as hostile input

Not "unreliable" — *hostile*. It can be influenced by anyone who can put text in front of the model, including
a customer's supplier's PDF.

**In practice:** structural untrusted-content framing; tool authorization independent of what the model asked
for; permission intersection on delegation.

**Cost accepted:** more plumbing than "just let the agent call the tool", and some capability we deliberately
do not grant.

## P8 — Prefer deletion to configuration

An option is a permanent obligation: it must be documented, tested in combination, and supported forever.
Default well; expose a knob only when tenants demonstrably differ.

**Cost accepted:** some tenants will want a knob we did not build.

## P9 — Optimize for the reader, at every layer

Code, events, errors, and docs are read far more often than written. Name things for the person debugging at
2 a.m. with no context, not for the person typing today.

**In practice:** the [domain glossary](../01-product/domain-glossary.md) is binding on schema and API naming;
errors carry correlation IDs; every alert links a runbook.

**Cost accepted:** longer names, more words, more upfront writing.

## P10 — Measure what you promise

Every guarantee in these docs has a metric, and every metric has an alert or it is not a guarantee.

**In practice:** projection lag SLIs for declared staleness budgets; cache-hit-rate SLI for the caching claim
in ADR-007; reconciliation jobs for the convergence claim in ADR-010.

**Cost accepted:** telemetry has real cost and maintenance burden.

---

## How to use these in review

When a change is contested, name the principle. "This adds a datastore with no measured threshold (P4)" is a
reviewable statement; "this feels like over-engineering" is not.

When two principles conflict — most often **P3 (boring)** vs. **P4 (evidence)** vs. a real performance need —
the resolution is an ADR, not a longer thread.
