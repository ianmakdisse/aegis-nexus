# Platform Glossary

> Technical and architectural vocabulary. Business vocabulary is in the
> [domain glossary](../01-product/domain-glossary.md).

## Architecture

| Term | Meaning here |
|------|-------------|
| **Control plane** | The Rails application that owns domain state and orchestrates everything. One codebase, many process *roles*. |
| **Process role** | A deployment of the same image with a different entrypoint (`api`, `worker`, `scheduler`, `relay`, `projector`, `consumer`). Roles scale independently. |
| **Modular monolith** | One deployable codebase, hard internal module boundaries, mechanically enforced. See [ADR-001](../11-decisions/ADR-001-architecture-style.md). |
| **Bounded context** | A domain module owning its tables and its language. Cross-context access happens only through published contracts. |
| **Published contract** | The narrow, versioned surface a context exposes: its commands, queries, and events. Everything else is private. |
| **Backbone** | The event transport. Pluggable: Postgres-durable-log locally, Kafka in production. See [ADR-003](../11-decisions/ADR-003-event-bus.md). |

## Distributed systems

| Term | Meaning here |
|------|-------------|
| **Outbox** | Table written in the same transaction as domain state; a relay publishes from it. Eliminates dual-write loss. |
| **Inbox** | Table of processed message IDs; a unique constraint makes redelivery a no-op. |
| **Effectively-once** | At-least-once delivery + idempotent handling. What we actually provide. |
| **Exactly-once** | A delivery guarantee we explicitly do **not** claim. |
| **Optimistic concurrency** | Version-checked writes; concurrent writers lose and retry rather than corrupt. |
| **Lease** | Expiring claim enabling crash recovery without distributed locks. |
| **Projection** | A derived read model built by consuming events. Always rebuildable, never authoritative. |
| **Upcasting** | Transforming an old event version into the current shape at read time. |
| **Snapshot** | A cached aggregate state at version N, so replay starts from N rather than 0. Pure optimization. |
| **Saga** | A sequence of local transactions with compensations, replacing distributed transactions. |
| **Poison message** | A message that fails deterministically; quarantined to a DLQ rather than retried forever. |
| **Backpressure** | Deliberately slowing or shedding intake when downstream cannot keep up. |

## Data

| Term | Meaning here |
|------|-------------|
| **RLS** | PostgreSQL Row-Level Security — the database-level half of tenant isolation. |
| **Tenant context** | Request-scoped `organization_id` propagated to DB session, cache keys, search filters, and prompts. Fails closed. |
| **Envelope encryption** | Data encrypted with a per-tenant data key; the data key encrypted by a KMS master key. Enables crypto-shredding. |
| **Crypto-shredding** | Erasing data by destroying its key, used where physical deletion conflicts with append-only logs. |
| **Hybrid retrieval** | Combining keyword (BM25) and vector similarity, fused and reranked. |

## Operations

| Term | Meaning here |
|------|-------------|
| **SLI / SLO** | Measured indicator / the target we commit to. Alerts fire on SLO burn, not on raw spikes. |
| **Blast radius** | The set of tenants/features affected by a given failure. |
| **Fail closed** | On ambiguity, deny. Applies to authorization and tenant context. |
| **Fail open** | On ambiguity, allow. Used only where availability outranks strictness, and always documented explicitly. |
| **Chaos experiment** | A controlled fault injection with a written hypothesis and pass/fail criteria. |
| **Runbook** | The procedure an on-call engineer executes for a specific alert. Every alert has one (NFR-502). |
