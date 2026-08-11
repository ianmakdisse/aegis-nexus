# Event Reference

> The wire format, the registry, and the rules that govern both.
>
> **Status:** ✅ format and registry implemented (Phase 5). The catalogue below lists the types that exist
> today — which is very few, because the contexts that emit them are Phases 6–10.

---

## Envelope format

Every event on the backbone has this shape. `headers` and `payload` are separate so a consumer can route and
trace without parsing domain data.

```json
{
  "event_id":       "9f2c…",          
  "event_type":     "workflow.run.started",
  "version":        1,
  "organization_id":"3a91…",
  "partition_key":  "run:7c1e…",      
  "occurred_at":    "2026-08-11T09:14:22.481Z",
  "trace_id":       "…",  "correlation_id": "…",  "causation_id": "…",
  "actor":          "membership:5d0…",
  "payload":        { }                
}
```

| Field | Rule |
|-------|------|
| `event_id` | Unique per event. The default dedup key for consumers |
| `event_type` | `context.aggregate.past_tense`. Must be registered before publishing |
| `version` | Integer, from 1. Additive-only within a version ([INV-10](../02-architecture/architecture-constitution.md#inv-10--events-are-versioned-and-additively-evolved)) |
| `partition_key` | **Required.** Ordering is guaranteed only among events sharing it ([INV-09](../02-architecture/architecture-constitution.md#inv-09--ordering-is-per-key-never-global)). Usually the aggregate id |
| `correlation_id` | The operation the whole chain belongs to. Minted if absent |
| `causation_id` | The event that directly caused this one. `nil` at the root of a chain |
| `actor` | Who caused it, as an opaque principal reference — never a credential |

`correlation_id` and `causation_id` are different on purpose: one lets you find every event in an operation,
the other lets you rebuild the tree from the list.

## Naming

`<context>.<aggregate>.<past-tense-verb>` — lower snake, dot-separated.

| Good | Why |
|------|-----|
| `workflow.run.started` | A fact that happened |
| `agent.execution.ceiling_exceeded` | Specific enough to handle without inspecting the payload |
| `billing.budget.exhausted` | Names the aggregate, not the handler |

| Avoid | Why |
|-------|-----|
| `workflow.run.update` | Not past tense — an event is a fact, not a command |
| `order.changed` | Too vague to subscribe to without parsing |
| `projection.rebuild_needed` | That is an instruction, not something that happened |

## Registry

Types live in `event_type_registry`, keyed `(key, version)` — platform-global, because the vocabulary
describes the software rather than a tenant ([ADR-012](../11-decisions/ADR-012-domain-schema.md)).

```ruby
Nexus::Events::EventType.register!(
  key: "workflow.run.started", version: 1,
  schema: { "run_id" => "string", "definition_key" => "string" },
  owning_context: "workflows"
)
```

Publishing an unregistered type raises. The log is permanent, so an undeclared type is an undeclared permanent
commitment — better refused at the publish than discovered in six months by a consumer that cannot handle it.

## Evolution

Within a version, fields may be **added**. Nothing may be removed or retyped — `register!` compares against the
stored schema and refuses, naming the offending fields.

```
v1 {id, name}  →  v1 {id, name, region}     ✅ additive
v1 {id, name}  →  v1 {id}                   ❌ removed name
v1 {count: string} → v1 {count: integer}    ❌ retyped
```

A breaking change registers `version: 2`. Version 1 keeps being handled until no stored event uses it — which
is a query against the log, not a judgement call.

## Ordering and delivery

| Guarantee | Reality |
|-----------|---------|
| Ordering | Per partition key only. Never global, never by wall clock |
| Delivery | **At-least-once.** Exactly-once is never claimed ([INV-06](../02-architecture/architecture-constitution.md#inv-06--we-never-claim-exactly-once-delivery)) |
| Processing | Effectively-once, via the inbox and idempotent handlers ([INV-05](../02-architecture/architecture-constitution.md#inv-05--every-distributed-operation-is-idempotent)) |

Every consumer declares a dedup key or the base class refuses to run it. See
[Events](../03-domains/events/README.md).

## Catalogue

Nothing is registered at boot yet: the contexts that emit events are still being built, and a catalogue of
types nobody publishes would be a list of intentions. Types appear here as their context lands.

| Type | Version | Owner | Emitted when | Status |
|------|---------|-------|--------------|--------|
| — | — | — | — | Phases 6–10 |

Expected first entries, from the aggregates [ADR-005](../11-decisions/ADR-005-event-sourcing.md) event-sources:
`workflow.run.*` (Phase 7), `agent.execution.*` (Phase 8), `approval.request.*` (Phase 7),
`audit.record.*` (Phase 10).

## Related
[Events](../03-domains/events/README.md) · [ADR-003](../11-decisions/ADR-003-event-bus.md) ·
[ADR-005](../11-decisions/ADR-005-event-sourcing.md) · [Schema](../06-data/schema.md)
