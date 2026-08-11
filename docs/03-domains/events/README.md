# Events

> The backbone. Captures facts, carries them, and guarantees they are not lost between the write that caused
> them and the handler that reacts.
>
> **Status:** ✅ publisher, transport port, relay, consumer and replay implemented and tested (Phase 5).
> The Kafka transport is Phase 14; everything runs today against PostgreSQL alone.

## Understanding This System

**Level 1 — Beginner.** When something important happens, we write it down in the same breath as the thing
itself — one atomic step, so there is no moment where the change happened but the record didn't. A separate
process then carries those records to whoever cares. If it delivers the same record twice, nothing breaks,
because every reader is built to recognise something it has already seen.

**Level 2 — Engineer.** Two mechanisms live here and are constantly confused:

| | Job | Table | Not for |
|---|---|---|---|
| **Event log** | Fan-out, replay, per-key ordering | `outbox_messages` → `event_log_entries` → `inbox_messages` | Delays and retries |
| **Event store** | The authoritative history of four aggregates ([ADR-005](../../11-decisions/ADR-005-event-sourcing.md)) | `event_store_events`, `event_store_snapshots` | Anything not event-sourced |

The scheduler — delays, retries, week-long waits — is a *third* thing and lives in Workflows
(`scheduled_jobs`). They solve different problems and cannot be substituted for one another
([ADR-003](../../11-decisions/ADR-003-event-bus.md)).

**Level 3 — Expert.** Three properties carry the design, and each is a specific bug made unwritable:

**No dual writes.** The outbox row commits with the state it describes, so the guarantee is a property of the
commit rather than a protocol between two components that must both be working. `Publisher` raises outside a
transaction — before writing anything.

**At-least-once, never exactly-once.** The relay publishes, then marks. A crash between the two republishes on
restart, and the log's unique index on `(organization_id, outbox_message_id)` absorbs it. We could make this
atomic on PostgreSQL and deliberately do not — Kafka cannot, so an atomic relay would behave differently per
transport and the duplicate path would never be exercised in CI.

**Consumption is per tenant.** Not a performance choice: `organizations` and the log are RLS-protected and no
application role bypasses policy, so there is no global scan available. This also gives per-tenant fairness for
free — one tenant's backlog cannot starve everyone else's.

## The path an event takes

```
domain write ─┐
              ├─ ONE transaction (INV-04)          Publisher.publish(envelope)
outbox row  ──┘
      │
      ▼  role: relay                                Relay.drain(organization_id:)
event_log_entries        partition = hash(partition_key) % 16     ← INV-09
      │
      ▼  role: consumer                             Consumer#handle(envelope)
inbox claim + handler ─ ONE transaction             ← a failed handler rolls the claim back
      │
      ├─ success   → cursor advances
      └─ 3 failures → dead_letter_messages, cursor advances anyway
```

The last arrow matters: leaving the cursor on a poison message would block that partition forever, turning one
bad event into a tenant-wide outage.

## The published contract

| | |
|---|---|
| `Events::Envelope` | The event: type, version, payload, partition key, trace/correlation/causation ids |
| `Events::EventType` | The vocabulary, and the additive-only rule (INV-10) |
| `Events::Publisher` | The only way an event enters the system. Raises outside a transaction |
| `Events::Relay` | Outbox → backbone. The `relay` role |
| `Events::Consumer` | Base class for handlers. The `consumer` role |
| `Events::Replay` | Re-deliver history (FR-208) |

`Nexus::Events::Transport` is the port ADR-003 specifies — `publish`, `read`, `commit`, `seek`, and nothing
more. It deliberately does not expose transactions, compacted topics, or partition assignment: if we ever need
those, we change the ADR rather than leak Kafka into domain code.

## Three rules that will bite you

**Every consumer must declare a dedup key.** The base class refuses to run a handler without one — a refusal,
not a warning, because duplicates *will* arrive and a handler without a key is a double side effect waiting for
a relay restart (INV-05). Derive it from something durable: the event id, or an aggregate id plus a version.

**The claim and the handler share one transaction.** The obvious implementation claims first and handles
second. If the handler then fails, the claim survives and every retry is deduplicated away — the message is
silently and permanently dropped, which is worse than the duplicate the inbox existed to prevent.

> Related, and found the hard way: `InboxMessage.claim` wraps its INSERT in a **savepoint**. In PostgreSQL a
> failed statement aborts the whole transaction, so rescuing `RecordNotUnique` without one leaves the
> transaction poisoned — the duplicate is then reported as a handler failure and dead-lettered.

**Rewinding a cursor does not replay anything.** The inbox has already claimed every key for that group, so a
naive replay reports success and changes nothing. Use `Replay.into_group` (a fresh group — safe, reversible)
or `Replay.reprocess!`, which purges the group's claims and requires an explicit acknowledgement that handlers
will re-run.

## Ordering

Guaranteed **only** among events sharing a partition key, which is the only guarantee Kafka can give and the
only one worth designing against (INV-09). Choosing the partition key *is* choosing what is ordered — usually
the aggregate id. A blank key is refused at construction, because the failure would otherwise surface much
later as one aggregate's events processed out of order, which is close to undebuggable.

## Schema evolution

The log is permanent, so a schema change is a change to **history**, not just to future messages. Within a
major version fields may be added; nothing may be removed or retyped. `EventType.register!` enforces this by
comparing against the stored schema and refusing an incompatible change, naming the offending fields. A
breaking change mints a new version, and the old one keeps being handled until no stored event uses it — which
is a query, not a guess.

## Tests

`spec/events/` — 33 examples covering the three scenarios ADR-003 says the transport port exists to make
runnable in CI: **duplicate delivery**, **replay**, and **crash recovery** (the relay is killed between
publishing and marking, then restarted, and the log must hold exactly one entry).

## Not built yet

| | |
|---|---|
| `KafkaTransport` | Phase 14. `Transport.build("kafka")` raises rather than stubbing — a transport that silently does nothing loses events while reporting success |
| Ingestion endpoint | `ingested_events` exists; the signed webhook receiver is Phase 10 (Integrations) |
| Event store usage | Tables exist; the aggregates that write to them are Phase 6 |
| Durable retry backoff | Consumers retry 3 times in process, then dead-letter. Scheduled backoff is Phase 7 |

## Related
[ADR-003](../../11-decisions/ADR-003-event-bus.md) · [ADR-005](../../11-decisions/ADR-005-event-sourcing.md) ·
[ADR-013](../../11-decisions/ADR-013-tenant-enumeration.md) — why consumption is per tenant ·
[Schema reference](../../06-data/schema.md)
