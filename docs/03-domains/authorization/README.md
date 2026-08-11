# Authorization

> Owns the answer to "may this principal do this, to this?" — for humans, services, and agents alike.
>
> **Status:** ✅ evaluator implemented and tested (Phase 4). Tool-call authorization (INV-20) arrives with the
> agent runtime in Phase 9; nothing here changes for it, because a tool call is an ordinary permission check
> with a machine principal.

## Understanding This System

**Level 1 — Beginner.** Identity says who you are. Authorization says what you may do. Everything is denied
unless something explicitly allows it — like a building where every door is locked and your badge opens only
the rooms you were given.

**Level 2 — Engineer.** RBAC with an ABAC overlay (FR-107): coarse role grants, refined by attribute
conditions (resource owner, environment, data classification, time, risk tier). Pure RBAC produces role
explosion; pure ABAC is unreviewable by non-engineers.

| Table | Holds |
|-------|-------|
| `roles` | Tenant-scoped roles, including seeded system roles |
| `permissions` | Global catalog of `resource.action` keys with a risk tier |
| `role_permissions` | Which permissions a role grants |
| `grants` | Binds a role to a **membership** or a **service identity** (exactly one — CHECK-enforced) |
| `policies` | ABAC conditions; `deny` wins |

Roles are seeded **per tenant** rather than shared globally, which keeps every authorization query inside one
tenant's rows and therefore inside RLS.

`permissions` is the exception: it is platform-global and has no `organization_id`, because a permission key
describes the *software*, not a tenant. It is one of exactly two INV-13 exemptions in the control plane (the
other is `users`, in Identity). Both are recorded in the RLS migration; a third requires an ADR.

**Level 3 — Expert.** Two properties do the heavy lifting:

**Authorization never reads stale state.** No projection, no cache beyond a single request
([ADR-010](../../11-decisions/ADR-010-consistency-model.md) Rule 1). A revoked permission honored for another
200 ms is not a latency optimization — it is a vulnerability. This is why Authorization is deliberately *not* a
CQRS context, and why there is no memoization inside `Authorize`.

**Delegated authority only narrows** ([INV-16](../../02-architecture/architecture-constitution.md#inv-16--delegated-authority-only-narrows)).
An agent's effective permissions are the **intersection** of its own grants and those of the principal it acts
for. There is no path by which delegation widens authority — otherwise the agent runtime becomes a universal
privilege-escalation device, and an attacker who can influence an agent's input inherits the invoker's rights.

Evaluation fails closed: an evaluator error is a denial, not an exception to be retried.

## How a decision is made

```
Authorize.call(principal, action, resource_type, attributes:)
  │
  ├─ 1. permission_key = "#{resource_type}.#{action}"
  │     not in the catalog?                          → DENY :undefined_permission
  │
  ├─ 2. PermissionSet.effective_for(principal)
  │       own grants (active, conditions satisfied)
  │       ∩ effective set of every principal it acts for      ← INV-16, no union anywhere
  │     key absent?                                   → DENY :no_grant
  │
  ├─ 3. tenant policies, ascending priority, first match decides
  │     match is `deny`?                              → DENY :policy_denied
  │
  └─ 4.                                               → ALLOW
```

Any exception at any stage → `DENY :evaluator_error`, logged at error level. `call!` raises `Denied` — a
decision — never the underlying fault, so that no caller can rescue a database error into an allow.

**Stage 1 is a security control, not a convenience.** A misspelled action at a call site (`:aprove`) must never
become a permission, and must never be reachable by a future prefix or wildcard rule.

### The permission catalog

Global vocabulary, defined in `domains/authorization/internal/catalog.rb`, installed by
`PermissionCatalog.install!` (idempotent; `db/seeds.rb` runs it). Risk tiers:

| Tier | Meaning |
|------|---------|
| `LOW` | Read-only, no side effects outside the platform |
| `MEDIUM` | Mutates tenant state |
| `HIGH` | Reaches the outside world, spends money, or moves authority |
| `CRITICAL` | Changes who may do what, or destroys data |

Permissions are never deleted by `install!` — `role_permissions.permission_key` references the table, so
retiring one is an expand/contract migration ([INV-11](../../02-architecture/architecture-constitution.md#inv-11--schema-changes-are-safe-for-rolling-deployment)),
not a side effect of editing a Ruby constant.

### System roles

Every tenant gets four, seeded by `SeedSystemRoles` during provisioning:

| Role | Holds |
|------|-------|
| `owner` | Every permission in the catalog |
| `admin` | Everything except the authority-moving CRITICALs (`roles.manage`, `grants.create`, `policies.manage`, `service_identities.manage`, `tools.register`, `integrations.connect`, `billing.manage`, `organizations.delete`) |
| `operator` | Every `LOW`-tier permission, plus running work: trigger/cancel/approve workflows, invoke agents and tools, ingest documents, call integrations, send notifications |
| `viewer` | Every `LOW`-tier permission |

Role templates expand into **explicit `role_permissions` rows** rather than being stored as a wildcard and
matched at request time. The cost is a backfill when the catalog grows; the benefit is that "what can an admin
actually do?" is a query, so an auditor, an incident responder, and the evaluator cannot disagree.

`operator` and `viewer` derive their read set from the `LOW` tier rather than from a hand-maintained list —
adding a read permission to the catalog cannot leave them behind.

### The policy language

`policies.matcher` is JSON. Every clause present must match (AND); an absent clause means "any".

| Clause | Matches against |
|--------|-----------------|
| `permissions` | The full `resource.action` key |
| `resource_types` | The resource type alone |
| `actions` | The action alone |
| `risk_tiers` | The permission's catalog tier |
| `attributes` | `{name: value \| [values]}` against the request's attributes |

```json
{ "resource_types": ["integrations"], "attributes": { "environment": "production" } }
```

Four rules, each of which is a test:

1. **A policy can only take authority away.** No `allow` policy grants a permission the principal's roles do
   not carry. An `allow` exists solely to carve an exception out of a broader `deny`, and it wins by having the
   lower `priority` number.
2. **A missing attribute never satisfies a condition.** A policy conditioned on `environment = production` is
   not bypassed by omitting `environment`. Silence is not consent — this applies identically to grant
   `conditions`, which share the matching implementation for exactly that reason.
3. **An empty matcher matches everything.** An empty `deny` is a tenant-wide lockout, and it is meant to be
   obvious that it is.
4. **Unknown clauses fail closed in both directions.** An unrecognized key makes a `deny` match and an `allow`
   not match, so a policy written against a future evaluator degrades to *more* restrictive, never to
   unenforced.

### Grants and the bootstrap problem

A grant binds a role to exactly one subject — a membership or a service identity — and may carry `conditions`
and an `expires_at`. Expiry is evaluated with the **database's** clock: a worker with a skewed clock must not
be able to honor a grant the database considers dead.

`membership_id` and `service_identity_id` are opaque UUID columns, not associations. Those tables belong to
Organizations and Identity, and INV-01 forbids reading them from here — a `belongs_to` would generate exactly
that query.

Granting a role requires `grants.create`, which is CRITICAL, which means the first grant in a tenant has nobody
to authorize it. Rather than an unauthenticated code path nobody can find later, `AssignRole` takes a
**required** `authorized_by:` that must be either a principal or the literal `:system_bootstrap`. Every place
authority is created without a human behind it is one grep away.

## Published contract

`Authorization::Authorize` · `Authorization::PermissionSet` · `Authorization::Policy` ·
`Authorization::PermissionCatalog` · `Authorization::AssignRole` · `Authorization::SeedSystemRoles`

> `SeedSystemRoles` exists because `boundary-check` rejected Organizations inserting into `roles` directly
> (INV-01). The fix published a capability rather than widening the rule — see
> [Organizations](../organizations/README.md#published-contract).

A **principal** here is anything responding to `organization_id` plus exactly one of `membership_id` or
`service_identity_id`, and optionally `acting_for` (the delegation chain). This context never names
`Identity::Principal`: it is not permitted to call Identity synchronously and does not need to — an opaque
subject identifier is the whole point of a boundary.

## Tests

`spec/authorization/` — 51 examples, organized by failure mode rather than by method. Proven non-vacuous by
mutation: replacing the delegation intersection with a union fails 3 examples; removing the deny-by-default
check fails 16.

## Related
[ADR-010](../../11-decisions/ADR-010-consistency-model.md) · [Identity](../identity/README.md) ·
[Organizations](../organizations/README.md)
