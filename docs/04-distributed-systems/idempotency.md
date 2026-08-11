# Idempotency

> Doing something twice must be indistinguishable from doing it once.
>
> **Status:** ✅ enforced where it exists (Phase 5). Steps and tool calls arrive with their runtimes
> (Phases 7–9). [INV-05](../02-architecture/architecture-constitution.md#inv-05--every-distributed-operation-is-idempotent).

---

## The premise

At-least-once delivery is not a defect to be engineered away. It is the substrate. Every retry, redelivery,
rebalance and crash recovery in this system can present the same logical operation twice, and the only
question is whether the second one is harmless.

So idempotency is not a property to add where convenient — it is the precondition for every handler,
and the base consumer refuses to run one that cannot state its key.

## Three kinds, and they need different mechanisms

**Naturally idempotent.** Setting a field to a value, upserting a row by key, applying an event to a read
model. Running it twice changes nothing. Most projections are here, which is why
[`Projection`](../03-domains/events/README.md) can default its dedup key to the event id.

**Made idempotent by a key.** Anything that would otherwise accumulate: incrementing a counter, appending a
row, charging money. These need a durable key and a uniqueness constraint. The database enforces it — never
a `find_by` the handler might race against.

**Not idempotent, and cannot be made so alone.** An external side effect: an HTTP POST to a partner, a model
invocation, an email. The remedy is to pass *our* idempotency key to them if they support one, and to record
locally that we attempted it before we attempt it — so a crash mid-call is recoverable as "unknown, check"
rather than "unknown, retry blindly".

## Where keys come from

**Derived from durable identifiers, never generated at call time.**

```
step execution   run_id + step_key + attempt
tool invocation  execution_id + tool + argument digest
event handling   event_id (unique per event, stable across redelivery)
outbox message   the outbox row's own id
```

A key that changes on retry defeats the mechanism it exists for. This is the single most common way
idempotency is implemented and does not work: the key is computed from a timestamp, a UUID, or the current
attempt's memory, so every retry looks like a new operation.

Enforcement is a unique index in every case — `step_executions.idempotency_key`,
`tool_invocations.idempotency_key`, `inbox_messages(organization_id, consumer_group, dedup_key)`,
`workflow_runs.idempotency_key`.

## The commit-after-effect problem

The hard case is not the duplicate. It is the crash *between* the effect and the record of it.

```
POST /charge  → succeeds
crash
retry         → charges again?
```

There is no way to make two independent systems atomic, so the pattern is: **write the intent durably before
acting, and derive the key from that durable row.** On recovery the row exists, so the retry presents the same
key, and either the remote deduplicates it or we can query for it.

This is why `step_executions` writes a row *before* the step runs and why every attempt is a new immutable row
rather than a counter — the previous attempt is the evidence of what was already tried.

## What "effectively-once" means, precisely

| Claim | True? |
|-------|-------|
| Each message is delivered once | **No.** At-least-once, always |
| Each message is *processed* once | Effectively, via dedup keys and unique indexes |
| Each external side effect happens once | Only where the remote supports idempotency keys; otherwise "at most one extra, detectably" |

We never say exactly-once
([INV-06](../02-architecture/architecture-constitution.md#inv-06--we-never-claim-exactly-once-delivery)),
because believing it causes engineers to skip exactly the work this page describes.

## Testing it

The test that matters is not "does the handler work". It is **run it twice and assert the second changed
nothing**. `spec/events/backbone_spec.rb` does this by rewinding a cursor and re-consuming — the same thing a
rebalance does in production — and asserts the handler ran once.

## Related

[Inbox](inbox-pattern.md) · [Outbox](outbox-pattern.md) · [Failure recovery](failure-recovery.md) ·
[Ordering](ordering-guarantees.md)
