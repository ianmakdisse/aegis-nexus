# ADR-013 — Platform processes enumerate tenants from a directory, not from `organizations`

| | |
|---|---|
| **Status** | Accepted |
| **Date** | 2026-08-11 |
| **Deciders** | Platform, Security, SRE |
| **Supersedes** | — |

---

## Context

Phase 5 built the outbox relay and the event consumer. Both are platform
processes: they do work on behalf of every tenant, in a loop, forever. Both
therefore need to answer a question nothing in the system could answer.

**Which tenants exist?**

`organizations` is RLS-protected with a policy keyed on its own `id`, and
[INV-14](../02-architecture/architecture-constitution.md#inv-14--tenant-isolation-is-enforced-at-three-independent-layers)
permits no application role to bypass policy — `db/roles.sql` explicitly strips
`BYPASSRLS` and `SUPERUSER` from `nexus_app` and `nexus_ro`. Clearing the
application-level tenant context does not help either: the database policy
compares against a session variable that is then unset, so the predicate is NULL,
so no rows match. Isolation fails closed exactly as designed.

The consequence is precise and was not anticipated when the isolation model was
built: **a correctly isolated system cannot list its own tenants.** Every
per-tenant background process — relay, consumer, projector, scheduler,
reconciliation, partition maintenance — is blocked on this, not just the two
built in Phase 5.

It is worth stating what is *not* in tension here. Nobody needs to read tenant
*data* across tenants. The relay needs a list of identifiers so it can open each
tenant's context in turn and do its work inside the isolation model, exactly as a
request does. The question is only where that list comes from.

## Requirements driving this decision

| ID | Requirement |
|----|-------------|
| [INV-14](../02-architecture/architecture-constitution.md#inv-14--tenant-isolation-is-enforced-at-three-independent-layers) | Three independent isolation layers; no role bypasses policy |
| [INV-13](../02-architecture/architecture-constitution.md#inv-13--every-business-row-is-attributable-to-exactly-one-tenant) | Exemptions from tenancy are enumerated and need an ADR |
| [ADR-003](ADR-003-event-bus.md) | The relay publishes committed outbox rows for every tenant |
| [ADR-009](ADR-009-multi-tenancy.md) | Pooled and dedicated placements are resolved per tenant |
| [FR-103](../01-product/requirements.md#fr-103) | 1 → 10⁵ tenants |

## Considered alternatives

### A. A privileged database role with a read policy on `organizations`

Add `nexus_platform`, plus `CREATE POLICY … FOR SELECT TO nexus_platform USING (true)`
and a column-level `GRANT SELECT (id, status)`.

**Advantages** — One source of truth; nothing to keep in sync, so nothing can
drift. The exposure is narrow and reviewable: column grants mean the role reads
two columns and cannot see names, slugs, or the `settings` JSONB. Named policies
show up in `\d+` output, which is how the provisioning exemption was reviewed
before SEC-003 removed it.

**Disadvantages** — It creates the first role for which the tenant predicate is
not the only rule in force. That is a category change, not a size change: every
existing statement about isolation becomes "…unless you are `nexus_platform`",
and every future reader must check which role a given process runs as before
trusting the guarantee. The blast radius of a leaked `nexus_platform` credential
is also unbounded in a way column grants only partly contain — `USING (true)` is
one careless `ALTER POLICY` away from full read access, and that edit would look
routine in a migration diff.

### B. `BYPASSRLS` on a platform role

**Advantages** — Trivial; one attribute; no schema change.

**Disadvantages** — Directly contradicts INV-14 and `db/roles.sql`, which strips
this attribute precisely because an operator "temporarily" granting it is how
isolation quietly stops being enforced (SEC-001). Rejected without further
analysis; it is listed because it is what gets reached for under time pressure.

### C. *(chosen)* A platform tenant directory, written during provisioning

A small table — `tenant_directory` — holding `organization_id`, `status`, region
and placement tier, and nothing else. It names a tenant but describes none, and
it carries no policy: a process asking which tenants exist cannot be restricted
to one tenant while asking. Written in the same transaction as the
`organizations` row.

**Advantages** — No role, anywhere, can read another tenant's *data*: the
isolation model is left exactly as it is, with no exceptions to remember. What is
exposed is the set of opaque UUIDs, which grants nothing on its own — the tenant
context is set from the authenticated principal, never from a caller-supplied
value, so knowing an id does not make it usable. Writing it inside provisioning's
existing transaction makes drift structurally impossible rather than a
reconciliation job's responsibility. And it is the same shape as `regions` and
`feature_flags`: platform topology, identical for every tenant.

**Disadvantages** — Two places record that a tenant exists, which is duplication
even when it cannot drift. The directory is readable by every application
connection, so it is a low-value but real enumeration surface: an attacker with a
database connection learns how many tenants exist and when each was created.
Anything added to this table later is exposed the same way, and the temptation to
add "just the slug" for a debugging convenience will be real.

## Decision

Platform processes enumerate tenants from `tenant_directory`, a platform-global
table holding the organization id, lifecycle status, region and placement tier —
and nothing else. It is written in the same transaction that creates the
organization, so a tenant cannot exist without a directory entry.
`Organizations::Tenant` is the published contract for reading it; no other
context queries the table directly.

The table carries `organization_id` and deliberately has **no RLS policy**,
which is a third category in `config/ownership.yml`: not `tenant_exempt` (those
rows have no tenant at all) but `rls_exempt` (this row has one and is still not
isolated). It is the only entry, and a test asserts the list does not grow.

`organizations` keeps its policy unchanged. No role gains `BYPASSRLS`, and no
role gains a read policy over another tenant's rows.

**The directory holds identifiers, not data.** Adding a column that describes a
tenant rather than locating one — a name, a slug, a setting, a count — requires a
new ADR, because it converts an enumeration surface into a disclosure one.

## Why

The decisive asymmetry is what each option costs when it is wrong.

Alternative A is wrong if the policy is ever widened, the column grant is ever
dropped, or a process is ever run as the wrong role. Each of those is a plausible
one-line change that reviews as routine, and the failure is silent: cross-tenant
reads that no test covers, because the tests assert what `nexus_app` can see.

Alternative C is wrong if the directory drifts from `organizations` — which the
shared transaction prevents — or if someone widens it, which requires adding a
column and is therefore visible in exactly the place migrations get reviewed.

We prefer the design whose failure mode is a visible schema change over the one
whose failure mode is a subtly-edited policy.

## Consequences

**What becomes true:**

- Every per-tenant background process has a supported way to find its work, and
  it uses the ordinary isolation path for the work itself — open the tenant's
  context, do the thing, close it.
- The statement "no application role can read another tenant's data" stays
  true without qualification. That is worth more than the duplication costs.
- Provisioning gains a second write. A failure to insert the directory row aborts
  provisioning, which is correct: a tenant no platform process can see would
  accumulate outbox rows that are never relayed and events that are never
  consumed — a silent, growing, invisible backlog.

**Obligations this creates:**

| Obligation | When |
|-----------|------|
| A reconciliation check asserting `tenant_directory` and `organizations` agree, as defence against direct database manipulation | Phase 12 |
| Per-tenant fair dispatch, so one large tenant cannot starve the rest of the loop | Phase 17 |
| Sharded enumeration once the directory outgrows a single scan per loop iteration | Phase 15 |

## Failure modes

| Failure mode | Detection | Impact | Mitigation |
|--------------|-----------|--------|------------|
| Directory row missing for a live tenant | Reconciliation check (Phase 12); outbox age alert on that tenant | That tenant's events are never relayed — silent and growing | Written in provisioning's transaction, so it cannot happen through the product |
| Directory row present for a deleted tenant | Relay opens a context and finds nothing; harmless | Wasted loop iteration | `status` filter; the enumeration contract returns active tenants only |
| Someone adds a descriptive column | Code review; this ADR names the rule | Enumeration surface becomes a disclosure surface | Requires a new ADR by decision, and a visible migration by mechanism |
| Directory read becomes the loop bottleneck at 10⁵ tenants | Loop iteration duration | Relay lag across all tenants | Shard the enumeration (Phase 15); the contract returns an enumerator, not an array, so callers already stream |

## Operational impact

**Adds:** one table, and one row per tenant. On-call should know that the answer
to "why is this tenant's queue not draining" now includes "is it in the
directory".

**Removes:** the need to decide, per background process, how it finds tenants —
which would otherwise have been solved differently in each one.

## Cost impact

Negligible: one narrow row per tenant, ~10⁵ rows at the target scale, read once
per loop iteration.

## Security impact

**Better:** the alternative that was not chosen is the one that would have
created a role permitted to read across tenants. Refusing it keeps INV-14
unqualified, and keeps the isolation suite's assertions true for every role that
exists.

**Worse:** the directory is an enumeration surface. Any application connection
can count tenants and see when each was created. That is a genuine, if minor,
information disclosure, and it is the price of not creating a privileged reader.
It is bounded only by the rule that this table holds identifiers and never
descriptions — a rule with no automated enforcement, which is the weakest part of
this decision.

## Scalability impact

A single scan per loop iteration is fine to ~10⁵ rows. Beyond that, the loop
should be sharded by directory range across relay replicas — which the table
supports and the contract's enumerator shape anticipates.

## Reversal criteria

| Trigger | Move |
|---------|------|
| The directory is found to have drifted from `organizations` through any path other than direct database manipulation | The shared-transaction argument is wrong; reconsider A with column grants |
| A second descriptive column is genuinely needed | Stop. That is alternative A's problem re-created with worse ergonomics — reconsider A |
| Enumeration becomes the relay's bottleneck | Shard by directory range before changing the model |

## Related decisions

[ADR-009](ADR-009-multi-tenancy.md) — the isolation model this works within ·
[ADR-003](ADR-003-event-bus.md) — the relay that surfaced the problem ·
[ADR-012](ADR-012-domain-schema.md) — the exemption lists this adds a third category to

## Related code

- `apps/control-plane/domains/organizations/tenant.rb`
- `apps/control-plane/domains/organizations/provision_organization.rb`
- `apps/control-plane/domains/events/relay.rb`
- `apps/control-plane/db/migrate/20260811000001_create_tenant_directory.rb`
