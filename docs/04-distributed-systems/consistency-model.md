# Consistency Model

> Which operations read fresh state, which tolerate staleness, and how you know which one you are writing.
>
> **Status:** 🟡 the rules are enforced where the code exists (authorization, event store, projections).
> Several classes below describe subsystems still to come. Decision:
> [ADR-010](../11-decisions/ADR-010-consistency-model.md).

---

## The rule that decides everything else

**Anything that can *deny* an action reads strongly consistent state.**

Everything else is a trade-off; this is not. A permission revoked at 10:00 and honoured at 10:00:01 is not a
latency optimisation — it is the window an attacker is removed in. So `Authorization::Authorize` has no cache
at all, reads the database on every request, and is deliberately *not* a [CQRS](cqrs.md) context.

The corollary is what makes the rest affordable: because denial is strongly consistent, almost everything else
can safely lag.

## Consistency classes

Every operation declares one. If you cannot say which class an operation is, the design is not finished.

| Class | Means | Examples | If it is stale |
|-------|-------|----------|----------------|
| **Strong** | Reads committed state, no cache | Authorization decisions, budget checks before spend, lease acquisition | Never permitted |
| **Read-your-writes** | A caller sees its own change immediately | A command returning its own result | The user retries and doubles the effect |
| **Eventual (bounded)** | Lags by a measured, alerted amount | Projections, dashboards, cost rollups | Stale, correct, self-healing |
| **Eventual (unbounded)** | No promise | Analytics, exports | Nobody should decide anything from it |

## How each is achieved here

**Strong** — one PostgreSQL primary per placement, read on the write connection, no Redis in the path. This is
the payoff from [ADR-002](../11-decisions/ADR-002-database.md): with a single authoritative store, "strongly
consistent" is the default rather than a distributed protocol.

**Read-your-writes** — a command returns its own result rather than re-reading through a projection. The
request flow does this structurally: `controller → domain command → response`, with no projection between the
write and what the caller is told.

**Eventual (bounded)** — projections, with lag measured per projection per tenant and the `projector` role
scaled on it. Bounded means *measured and alerted*, not "probably fast".

## Where staleness is deliberately accepted

Two places, both argued explicitly rather than inherited by accident:

**Access tokens are stale identity for up to 15 minutes**
([ADR-011](../11-decisions/ADR-011-authentication.md)). A token asserts *who*, never *what may be done*, so a
revoked permission still stops the caller on the next request. Identity staleness is bounded and cheap;
authority staleness is neither.

**Projections lag.** A dashboard showing a workflow as "running" for another two seconds after it finished
costs nothing. The same lag in an authorization decision would be a vulnerability — which is the whole reason
the two live in different consistency classes.

## Time is not a coordination primitive

Wall-clock comparison across machines decides nothing here.

- Ordering comes from sequence numbers and partition keys, never timestamps
  ([ordering](ordering-guarantees.md)).
- Lease expiry uses the **database's** clock, so a worker with skew cannot honour a lease the database
  considers dead.
- Grant expiry uses `now()` in the query, for the same reason.

Timestamps exist for humans and for audit.

## Questions to ask of any new operation

1. Can this operation **deny** something? → strong, no cache, no exceptions.
2. Does the caller need to see its own write immediately? → read-your-writes; return the command's result.
3. Is it a view? → eventual, and say what the acceptable lag is *before* shipping it.
4. Would a stale read here cause a wrong decision, or just a stale screen? If you cannot answer, it is the
   first one.

## Related

[CQRS](cqrs.md) · [Event sourcing](event-sourcing.md) · [Ordering](ordering-guarantees.md) ·
[ADR-010](../11-decisions/ADR-010-consistency-model.md) ·
[Authorization](../03-domains/authorization/README.md)
