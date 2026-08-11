# Start Here

> You know nothing about this system. This page gets you to *useful* in about 20 minutes, and tells you
> exactly where to go next for anything deeper.
>
> **Before you trust anything here:** read [project-state.md](project-state.md) to see what is actually built
> versus designed. Much of `/docs` describes the system as decided, not as shipped — deliberately, because
> architecture decisions are recorded before implementation
> ([INV-25](../02-architecture/architecture-constitution.md#inv-25--significant-architectural-decisions-have-an-adr-written-before-implementation)).

---

## The twelve questions

### 1. What is Aegis Nexus?

An **autonomous distributed operations and intelligence platform**. It sits between a company's systems, its
people, and a fleet of AI agents, turning events from those systems into governed decisions, durable workflows,
human approvals, and auditable actions.

→ [Product overview](../01-product/product-overview.md)

### 2. What problem does it solve?

Organizations don't lack software; they lack anything reliable **between** their software. The gaps get filled
by humans copying data between tabs, brittle point-to-point scripts, and business rules buried in application
code. Adding LLMs naively makes this worse: an agent with a database connection and no permission boundary is
a breach with a friendly interface.

Aegis Nexus provides one durable, observable, governed operational layer, so that this sentence is true for
thousands of tenants at once:

> *Every meaningful thing that happened in our business was captured, evaluated against our policies, acted on
> by a person or an agent operating inside explicit limits, and is fully reconstructable six months later.*

### 3. What are the major subsystems?

Eleven bounded contexts, grouped by role:

| Group | Contexts | Job |
|-------|----------|-----|
| Foundation | Identity, Organizations, Authorization | Who you are, whose data it is, what you may do |
| Operational core | Events, Workflows, Agents | Capture facts, execute durably, decide within limits |
| Capabilities | Integrations, Documents/Knowledge, Notifications | Reach the outside world; know things; tell people |
| Governance | Billing/Cost, Audit | What it cost; prove what happened |

→ [Context map](../02-architecture/context-map.md) (ownership + who may call whom) ·
[System overview](../02-architecture/system-overview.md) (six abstraction levels)

### 4. How do they communicate?

**Asynchronously by default, through versioned events**
([INV-03](../02-architecture/architecture-constitution.md#inv-03--contexts-communicate-asynchronously-by-default)).
Synchronous calls are the exception and must be individually declared with a justification and a defined
degradation — the list is short and lives in
[`config/ownership.yml`](../../apps/control-plane/config/ownership.yml), enforced by
[boundary-check](../../tools/boundary-check/README.md).

Contexts never read each other's tables. Not with a join, not read-only, not once.

### 5. Where does data live?

**PostgreSQL, for everything authoritative** ([ADR-002](../11-decisions/ADR-002-database.md)) — domain state,
event store, outbox, workflow runs, audit, usage records, and embeddings.

| Store | Holds | Authoritative? |
|-------|-------|----------------|
| PostgreSQL | Everything above | **Yes** |
| Redis | Cache, rate limits, locks, live-push fan-out | **No** — losing it must never lose data ([INV-08](../02-architecture/architecture-constitution.md#inv-08--redis-is-never-the-source-of-truth-for-durable-business-state)) |
| Kafka | Event transport | **No** — the event store is the replay source, not the broker |
| Object storage | Uploaded document bytes | Yes, for blobs |

Tenant data is isolated at three independent layers: PostgreSQL RLS, application scoping, and request-scoped
context that fails closed ([ADR-009](../11-decisions/ADR-009-multi-tenancy.md)).

### 6. Where does asynchronous processing occur?

In **worker roles** — the same container image booted with a different `NEXUS_ROLE`
([`config/roles.yml`](../../apps/control-plane/config/roles.yml)):

`relay` (outbox → backbone) · `consumer` (backbone → handlers) · `projector` (events → read models) ·
`worker:default` (steps, timers, retries) · `worker:agents` · `worker:documents` · `scheduler` (leader-elected).

Two distinct mechanisms, often confused
([ADR-003](../11-decisions/ADR-003-event-bus.md)): the **event log** (Kafka — fan-out, replay, per-key
ordering) and the **scheduler** (a PostgreSQL due-time queue — delays, retries, week-long waits). They solve
different problems and cannot be substituted for one another.

### 7. Where does AI execute?

In the **agent runtime**, inside the `worker:agents` role. We own the agent loop rather than delegating it,
because permission checks, budget ceilings, argument validation, audit, and *suspension for human approval*
all have to happen between every model turn and every tool call — and a durable suspension may last days
([ADR-007](../11-decisions/ADR-007-ai-runtime.md)).

Three rules to internalize before touching anything AI:

1. Model output is **data, never instruction** ([INV-19](../02-architecture/architecture-constitution.md#inv-19--model-output-is-data-never-instruction)).
2. No tool runs without an authorization decision ([INV-20](../02-architecture/architecture-constitution.md#inv-20--no-tool-executes-without-an-authorization-decision)); the model's request is a *proposal*.
3. An agent's permissions are the **intersection** with its invoker's — delegation narrows, never widens ([INV-16](../02-architecture/architecture-constitution.md#inv-16--delegated-authority-only-narrows)).

### 8. Where do workflows execute?

In a **durable interpreter we built on PostgreSQL** ([ADR-006](../11-decisions/ADR-006-workflow-engine.md)) —
the highest-risk decision in the system, and documented as such.

The properties that make it work: state is durable before a step is attempted; workers hold **leases** (which
expire) rather than locks (which don't survive a crash); every attempt is a new immutable row; runs are pinned
to a workflow *version* so editing a definition can't corrupt in-flight runs; and a waiting run costs one
indexed row and zero workers.

### 9. How does a request travel through the system?

```
Client → Ingress → api role
  → authenticate (principal)                     Identity
  → resolve tenant + placement, open connection  Organizations   ← fails closed if absent
  → authorize (deny by default)                  Authorization   ← strongly consistent, never cached
  → controller → domain command
  → BEGIN … domain write + outbox row + audit record … COMMIT    ← one transaction (INV-04)
  → response returns the command's own result                    ← read-your-writes without coordination
```

### 10. How does an event travel through the system?

```
webhook → verify signature + freshness → inbox dedup → store → 202 Accepted   ← "stored", not "processed"
        → outbox row (same transaction)
relay   → publish to backbone
consumer→ inbox dedup → idempotent handler
        → workflow triggered / projection updated / usage metered / audit written
projector → read model → Redis pub/sub → WebSocket → UI
```

Two things worth pausing on: the 2xx to the provider means **durably stored**, never processed (FR-202); and
delivery is **at-least-once**, so every handler must be idempotent
([INV-05](../02-architecture/architecture-constitution.md#inv-05--every-distributed-operation-is-idempotent)).
We never claim exactly-once.

### 11. What happens when components fail?

There is a full matrix — 33 dependencies × detection, impact, recovery, data loss, user impact, and the test
that proves it: [failure domains](../02-architecture/failure-domains.md).

The cross-cutting rules:

| Rule | Meaning |
|------|---------|
| Ingestion never depends on processing | Broker down ⇒ events accumulate in the outbox; nothing is lost |
| Derived data failure is never data loss | Projections, caches, indexes are rebuildable by construction |
| External slowness is contained | Timeouts + circuit breakers; their outage is not ours |
| Crash-after-effect is designed for | Idempotency keys derived from durable identifiers |
| Time is not a coordination primitive | Lease expiry uses the **database's** clock |
| AI failures degrade to humans | Never to silent wrong answers |

> ⚠️ Every "recovery" cell is a **hypothesis** until its chaos test exists. The matrix labels them as such
> rather than presenting them as guarantees.

### 12. Where should a developer look when debugging?

Start from the symptom:

| Symptom | Look here | First thing to check |
|---------|-----------|----------------------|
| Workflow stuck | `workflow_runs`, `step_executions`, `run_leases` | Is it `sleeping` (waiting on purpose) or is its lease not being reclaimed? |
| Automation didn't run | `outbox_messages` age, consumer lag, `dead_letter_messages` | Did the event get published, delivered, and handled? Three different failures. |
| Dashboard stale/wrong | Projection lag SLI, then reconciliation results | Lag = stale (wait). Divergence = wrong (rebuild). Different problems. |
| Cross-tenant data | **Stop, treat as a security incident** | [tenant isolation](../08-security/tenant-isolation.md) |
| Agent did something unexpected | `agent_executions` timeline | Prompt hash, tool calls, arguments, denials, refusal category |
| Cost spike | `usage_records`, then the execution's tier + effort + cache-hit tokens | Almost always tier, effort, or a broken prompt cache |
| Duplicate side effect | Inbox dedup counter, step idempotency key | Was the key derived from something durable? |
| Everything slow | DB pool saturation, then per-role metrics | Which role is starving? |

Every request and async execution carries `trace_id`, `span_id`, and `correlation_id`
([INV-23](../02-architecture/architecture-constitution.md#inv-23--every-significant-operation-is-traceable-end-to-end)) —
start from the correlation ID and the whole story is one query.

---

## "I need to understand X → read Y"

| I need to understand… | Read |
|-----------------------|------|
| What the product does | [Product overview](../01-product/product-overview.md) |
| Who we build for | [Personas](../01-product/personas.md) |
| Concrete end-to-end scenarios | [Use cases](../01-product/use-cases.md) |
| The numbered requirements | [Requirements](../01-product/requirements.md) |
| **The rules I must not break** | **[Architecture Constitution](../02-architecture/architecture-constitution.md)** |
| Judgment calls the rules don't cover | [Principles](../02-architecture/architecture-principles.md) |
| The big picture at six zoom levels | [System overview](../02-architecture/system-overview.md) |
| Who owns what, who may call whom | [Context map](../02-architecture/context-map.md) |
| What breaks when X dies | [Failure domains](../02-architecture/failure-domains.md) |
| Where the data lives and why | [Database architecture](../06-data/database-architecture.md) |
| What a given table is for | [Schema reference](../06-data/schema.md) |
| **Why anything is the way it is** | **[ADR index](../11-decisions/README.md)** |
| Which decisions constrain which | [Decision graph](../11-decisions/README.md#the-decision-graph) |
| What's actually built | [Project state](project-state.md) |
| Words and what they mean here | [Platform glossary](glossary.md) · [Domain glossary](../01-product/domain-glossary.md) |
| Why a boundary check can fail my build | [boundary-check](../../tools/boundary-check/README.md) |
| Why a broken link can fail my build | [docs-lint](../../tools/docs-lint/README.md) |
| What we know is wrong | [Technical debt](../technical-debt.md) |

---

## The documentation contract

`/docs` is a build artifact, not a courtesy. Four rules make it trustworthy:

1. **Documentation ships with the change.** A change altering documented behavior updates the docs in the same
   pull request ([INV-26](../02-architecture/architecture-constitution.md#inv-26--documentation-is-part-of-the-change)).
2. **CI enforces it.** Broken links, dangling anchors, undeclared forward references, and missing code paths
   fail the build ([docs-lint](../../tools/docs-lint/README.md)).
3. **Decisions are recorded before implementation**, with the alternatives that were genuinely considered and
   the evidence that would reverse them. No retrofitted justification.
4. **Uncertainty is stated.** Unverified claims are labeled. `project-state.md` outranks every other document
   on the question of what exists.

Every complex subsystem also carries an **Understanding This System** section written at three levels —
beginner (analogy), engineer (implementation), expert (distributed-systems implications). Explaining a thing
three ways is how we find out whether we actually understand it.

---

## Your first week

| Day | Do this |
|-----|---------|
| 1 | This page → [Constitution](../02-architecture/architecture-constitution.md) → [project state](project-state.md) |
| 2 | [System overview](../02-architecture/system-overview.md) + [context map](../02-architecture/context-map.md); run `ruby tools/boundary-check/check.rb` and read what it enforces |
| 3 | [ADR-001](../11-decisions/ADR-001-architecture-style.md), [002](../11-decisions/ADR-002-database.md), [003](../11-decisions/ADR-003-event-bus.md) — the load-bearing three |
| 4 | Trace [UC-01](../01-product/use-cases.md#uc-01--high-value-order-requires-governed-decisioning-canonical) end to end through the code |
| 5 | [Failure domains](../02-architecture/failure-domains.md); pick one hypothesis and check whether its test exists |

Then ship something small. If any of the above was wrong, unclear, or missing — **fix the doc in the same PR**.
Being new is the only time you can see what's confusing, and that perspective is worth more than the ramp-up
time it costs.
