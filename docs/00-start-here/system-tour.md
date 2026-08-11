# System Tour

> 30 minutes, one scenario, end to end. Follow the same order (UC-01) that every other document uses, so the
> pieces line up with what you read elsewhere.
>
> Prerequisite: [mental model](mental-model.md).

---

## The scenario

A retailer's shop sends a webhook: **order #4471, R$ 8,500**. Company policy says high-value orders need a
risk check, and anything over R$ 5,000 needs a human to sign off. We'll follow that order through the platform.

---

## Stop 1 — The edge (≈2 min)

```
POST /webhooks/shop-provider
X-Signature: sha256=...
X-Timestamp: 2026-08-10T14:22:01Z
```

Three checks before anything else:

1. **Signature** — HMAC, constant-time comparison. Forged ⇒ 401 + security event.
2. **Freshness** — timestamp inside a window. Old-but-valid ⇒ 401 (replay defense).
3. **Dedup** — `INSERT` into `inbox_messages`; unique violation ⇒ we've seen it ⇒ 200 OK, no work.

Then one transaction: raw payload → `ingested_events`, event → `outbox_messages`, `COMMIT`, `202 Accepted`.

> **The 202 means "durably stored", not "processed".** If we processed synchronously, the provider's timeout
> would become our availability problem and their retry would become our duplicate problem. Instead their retry
> hits check 3 and does nothing.

📖 [Event flow](../02-architecture/event-flow.md)

## Stop 2 — Publication (≈3 min)

The `relay` role claims unpublished outbox rows (`SKIP LOCKED`) and publishes with partition key
`hash(org_id, aggregate_id)`.

Why an outbox rather than publishing directly? Because of this:

```
COMMIT;                    ← order stored
   ← process dies
publish(OrderCreated)      ← never happens
```

No error. No alert. The order exists and nothing downstream knows, forever. With the outbox, the event row
committed *with* the order; the relay can crash freely.

📖 [ADR-003](../11-decisions/ADR-003-event-bus.md) · [outbox pattern](../04-distributed-systems/outbox-pattern.md)

## Stop 3 — Consumption (≈3 min)

A consumer receives it (at-least-once), dedups on `message_id`, and runs the handler. The handler matches a
trigger rule and creates a **workflow run**, pinned to the current published **version** of the definition.

That pinning is the reason a tenant can edit their workflow this afternoon without corrupting the 4,000 runs
already in flight.

📖 [Workflow versioning](../03-domains/workflows/versioning.md)

## Stop 4 — Durable execution (≈5 min)

The run begins. Each step:

1. A worker **claims a lease** (with an expiry — not a lock).
2. Writes a `step_execution` row **before** attempting the step.
3. Executes.
4. Records the outcome as a new immutable row. Retries never mutate history.

If the worker dies at step 3, the lease expires and another worker reclaims the run within ~30 s. The step is
retried — which is safe because steps carry idempotency keys derived from `(run_id, step_id, attempt)`.

Steps here: fetch inventory, fetch customer history, compute risk score. Then an agent step.

📖 [ADR-006](../11-decisions/ADR-006-workflow-engine.md) · [runtime](../03-domains/workflows/runtime.md)

## Stop 5 — The agent (≈7 min)

The most heavily governed part of the system. Before any model call:

- **Budget check** — reads authoritative rows, in a transaction. Exhausted ⇒ halt before spending.
- **Ceilings** — tokens, cost, wall-clock, tool calls, recursion depth.
- **Permission set** — the agent's grants ∩ the invoking principal's. Delegation narrows, never widens.

Prompt assembly has exactly three zones:

| Zone | Contents | Trusted? |
|------|----------|----------|
| System policy | Platform rules + agent instructions | Yes — and byte-stable, so it caches |
| Tool definitions | From the registry, strict schemas | Yes |
| **Everything else** | Retrieved docs, tool results, event payloads, prior model output | **No** — framed as data |

The model proposes tool calls. Each one is authorized *by the platform*, arguments validated against a strict
schema, then executed with a timeout and a rate limit. A `HIGH` risk-tier tool suspends the run for approval.

The model returns a recommendation with confidence 0.62.

📖 [ADR-007](../11-decisions/ADR-007-ai-runtime.md) · [agent runtime](../05-ai/agent-runtime.md)

## Stop 6 — The human (≈4 min)

Policy: `amount > 5000 OR confidence < 0.75 ⇒ require approval`. Both fire.

The run persists an approval request with full context and goes to `sleeping`. **It now consumes zero
workers, zero threads, zero connections** — it is a row with a wake condition.

Priya approves eleven hours later, using a single-use token bound to `(run, step, approver)` with an expiry.
Redemption is transactional; a replayed token is a hard failure and a security event.

The run resumes at exactly the step it left — in a different process, after a deploy, possibly in a different
availability zone.

📖 [Human-in-the-loop](../05-ai/human-in-the-loop.md)

## Stop 7 — Acting and recording (≈4 min)

The workflow calls external systems, each with a registered compensation so a later failure can semantically
undo it (there is no distributed rollback — only compensating actions).

Along the way, in the same transactions as the state changes:

- **Audit records** — hash-chained, tamper-evident. Never async: an audit trail that can lag can also lose.
- **Usage records** — tokens in/out/cached, model, tier, effort, cost. This is what makes a cost spike
  explainable rather than merely visible.

## Stop 8 — Seeing it (≈2 min)

Projectors consume the events and update read models; a Redis pub/sub message fans out to WebSockets and
Priya's dashboard updates.

If Redis is down, the push is lost — and nothing else is. The durable record is in PostgreSQL, and the UI
self-heals on refresh. That is what "Redis is never authoritative" means in practice.

📖 [ADR-004](../11-decisions/ADR-004-cqrs.md)

---

## What you just saw

| Idea | Where it appeared |
|------|-------------------|
| Durable before processed | Stop 1 |
| No dual writes | Stops 1, 7 |
| At-least-once + dedup | Stops 1, 3 |
| Version pinning | Stop 3 |
| Leases, not locks | Stop 4 |
| Idempotent retries | Stop 4 |
| Fail closed on budget and permission | Stop 5 |
| Untrusted content framing | Stop 5 |
| Suspension without resource cost | Stop 6 |
| Single-use, bound approval tokens | Stop 6 |
| Compensation over rollback | Stop 7 |
| Synchronous audit | Stop 7 |
| Derived data is disposable | Stop 8 |

## Next

[Developer onboarding](developer-onboarding.md) (get it running) ·
[Codebase navigation](codebase-navigation.md) (find the code) ·
[Constitution](../02-architecture/architecture-constitution.md) (the rules)
