# CQRS and Projections

> Separate read models from the write path — in the contexts where reads and writes genuinely conflict, and
> nowhere else.
>
> **Status:** ✅ projection machinery implemented (Phase 6). Concrete read models arrive with their contexts
> (Phases 7–10). Decision: [ADR-004](../11-decisions/ADR-004-cqrs.md).

---

## Per context, not globally

CQRS is applied where the read and write requirements actually differ. It is **not** applied to
Authorization, deliberately: a decision that can *deny* an action must read strongly consistent state
([ADR-010](../11-decisions/ADR-010-consistency-model.md) Rule 1), so a revoked permission is revoked now
rather than whenever a projection catches up.

That exception is the point of the whole decision. A globally-applied pattern would have made the security
boundary eventually consistent by default, and nobody would have noticed until it mattered.

## A projection is a consumer

```ruby
class RunSummary < Nexus::Projections::Projection
  projects "workflow.run.started", "workflow.run.finished"

  def project(envelope) = …update the read model…
  def reset!            = …truncate it for this tenant…
end
```

It inherits **checkpointing** (the consumer group's cursor) and **deduplication** (the inbox) from the
[event backbone](../03-domains/events/README.md) rather than growing its own. A separate checkpoint table
would be a second mechanism to keep correct, and its first bug would look exactly like a projection that
silently stopped updating.

Each projection gets its own group, so adding one does not replay the others, and a slow one does not hold
back its neighbours.

## Derived data is never authoritative

Everything a projection writes must be reconstructible from the event log **by construction**. That is what
makes a projection failure a *delay* rather than data loss.

`reset!` is a required method, not an optional one. A projection that cannot be truncated cannot be rebuilt,
and a read model that cannot be rebuilt is authoritative by accident — which quietly repeals the property
above.

## Rebuild is three steps, and skipping any one fails silently

| Step | If skipped |
|------|-----------|
| Truncate the read model | Double-counts — the projection re-applies what it already applied |
| Purge the group's inbox claims | The replay is deduplicated away; it reports success and changes **nothing** |
| Rewind the cursor | Nothing replays at all |

The middle one is the trap. Rewinding a cursor alone looks like a rebuild and does nothing, which is the worst
possible behaviour for an operation someone reaches for during an incident. `Projections::Rebuild` does all
three and drains to completion before returning, so nobody inspects a half-rebuilt model and concludes the
rebuild was wrong.

## Lag is not divergence

This distinction belongs in your head before the alert fires.

| | Means | Action |
|---|---|---|
| **Lag** | The read model is *correct and behind* | Wait, or scale the `projector` role |
| **Divergence** | It processed everything and still disagrees with the log | Rebuild — this is a bug in `project` |

`Projections::Runner.lag` measures the first: log head minus cursor position, per projection, per tenant.
Detecting the second requires reconciling the read model against the event store and is Phase 12.

Conflating them is why "the dashboard is wrong" gets answered with "wait a minute" for an hour.

## Isolation of the read path

The `projector` role runs alone (`config/roles.yml`). It never shares a process with `api`, so a projection
catching up on six months of history cannot consume the threads serving latency-sensitive traffic, and never
with `consumer`, so a rebuild cannot starve ordinary event handling.

The registry enforces this: consumers declare which role runs them, and a projection is never returned to the
`consumer` role's loop.

## What is not built

Concrete read models — there are none yet, because the contexts that own them are Phases 7–10. The machinery
is proven against a test projection that exercises checkpointing, skipping, rebuild and lag; persistence is
each subclass's own business, and `reset!` is where the base class holds it to account.

Redis pub/sub fan-out to WebSockets (the last hop in the read path) is Phase 11.

## Related

[Event sourcing](event-sourcing.md) · [Consistency model](consistency-model.md) ·
[Failure recovery](failure-recovery.md) · [ADR-004](../11-decisions/ADR-004-cqrs.md)
