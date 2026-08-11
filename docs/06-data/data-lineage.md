# Data Lineage

> How to answer "where did this value come from?" — for a number on a dashboard, a decision an agent made, or
> a row someone disputes.
>
> **Status:** 🟡 the mechanisms exist (event store, correlation and causation, projections). The audit chain
> and the query surface that make lineage *convenient* are Phases 10 and 12.

---

## Why this is answerable at all

Most systems cannot answer it. They store current state, so "why is this 47?" has no evidence behind it —
only the number, and whatever the logs happened to retain.

Three properties here make lineage recoverable rather than reconstructed:

1. **The event log is permanent.** Facts are appended, never updated. The reason a value is what it is
   remains in the store after the value changes.
2. **Every event carries `correlation_id` and `causation_id`.** One identifies the whole operation; the other
   identifies the single event that directly caused this one. Together they turn a flat list into a tree.
3. **Derived data is rebuildable by construction.** A projection's value is a pure function of the events it
   consumed, so lineage for a read model is the lineage of its inputs — nothing else can have influenced it.

## The three identifiers, and why they are not one

| Field | Answers |
|-------|---------|
| `trace_id` | Which request or job was executing (the technical span) |
| `correlation_id` | Which business operation this belongs to — stable across every hop, hours or days later |
| `causation_id` | Which single event directly caused this one |

Collapsing correlation and causation into one field is the common mistake, and it loses the tree: you can
still list everything that happened, but not what caused what. A workflow that fans out to five steps, three
of which emit further events, is a list of nine events under one correlation and a *shape* under causation.

`Envelope#caused` exists so the chain cannot be broken by forgetting to copy two fields:

```ruby
child = parent.caused(event_type: "workflow.step.started", payload: …)
# correlation_id preserved, causation_id = parent.event_id
```

## Tracing a value backwards

**For an event-sourced aggregate** — the history *is* the lineage. Load the stream and every state transition
is there in order, with the actor and correlation on each event.

**For a projection** — a read model value is a fold over events for that group. Rebuilding is the strongest
lineage check available: if a rebuild produces a different value, the difference is the bug, and the log is
right.

**For an operation** — one query on `correlation_id` returns every event in the chain across contexts, plus
(from Phase 10) the audit records for the same operation.

**For an AI decision** — `agent_executions` records model, version, prompt hash, tool calls with arguments and
results, tokens, cost, and refusals ([INV-21](../02-architecture/architecture-constitution.md#inv-21--every-ai-action-of-consequence-is-auditable)).
The prompt itself is deliberately not stored: the hash proves which prompt was used without retaining
customer content or secrets indefinitely.

## What lineage cannot tell you today

Stated plainly, because a lineage doc that implies completeness is worse than none:

- **Field-level lineage** — which specific input produced which specific output field. The events record
  what happened, not a dataflow graph. Reconstructing that needs the applier's logic, which lives in code.
- **Cross-tenant or cross-region lineage** — every query is tenant-scoped by construction, so a lineage query
  never spans tenants. This is a feature, and it means aggregate lineage across the platform is not a thing
  this design supports.
- **Anything before an event existed.** Contexts that do not yet emit events (most of them) have no lineage
  beyond their current rows.
- **Tamper evidence** — that comes from the audit hash chain (`audit_records.prev_hash`), which is Phase 10.
  Until then lineage is *recoverable*, not *provable*.

## Interaction with erasure

An append-only log and a right-to-erasure requirement (NFR-602) are in genuine tension. The intended remedy is
crypto-shredding — encrypt personal data with a per-subject key and destroy the key — which keeps the lineage
*structure* intact while making the content unrecoverable. That depends on the key hierarchy from unresolved
question Q1 and is designed in [data retention](data-retention.md), Phase 13.

Until then, no personal data should enter an event payload that is not also erasable by other means. This is a
constraint on payload design *now*, not a Phase 13 problem.

## Related

[Event sourcing](../04-distributed-systems/event-sourcing.md) · [CQRS](../04-distributed-systems/cqrs.md) ·
[Event reference](../13-reference/events.md) · [Schema](schema.md) ·
[Data retention](data-retention.md)
