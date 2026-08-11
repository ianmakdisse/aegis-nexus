# Organizations & Tenancy

> Owns the tenant: who they are, where their data lives, and — with Identity and Authorization — the
> machinery that keeps one tenant's data away from another's.
>
> **Status:** ✅ implemented and verified (Phase 3). Ten isolation examples pass and are non-vacuous.

---

## Understanding This System

### Level 1 — Beginner

Imagine a bank vault with thousands of safe-deposit boxes. Every customer's belongings are in the same
building, but a customer can only open their own box.

Aegis Nexus works the same way. Thousands of companies ("organizations", or *tenants*) share the same
database. Every row belongs to exactly one of them, and the system's most important job is making sure a
request made by one company can never see another's data.

The bank does not rely on the clerk remembering whose box is whose. There are locks. We have three.

### Level 2 — Engineer

Isolation is enforced at three independent layers ([INV-14](../../02-architecture/architecture-constitution.md#inv-14--tenant-isolation-is-enforced-at-three-independent-layers)):

| Layer | Mechanism | Where |
|-------|-----------|-------|
| **(a) Database** | PostgreSQL Row-Level Security policies keyed on a session variable | `db/migrate/*_enable_row_level_security.rb`, `infrastructure/database/row_level_security.rb` |
| **(b) Application** | `TenantScopedRecord` default scope + create-time stamping + cross-tenant write validation | `app/models/tenant_scoped_record.rb` |
| **(c) Context** | Request/job-scoped tenant that **raises when absent** | `infrastructure/tenancy/context.rb` |

The policy predicate is the load-bearing detail:

```sql
organization_id = NULLIF(current_setting('nexus.organization_id', true), '')::uuid
```

`current_setting(…, true)` yields NULL when unset; `NULLIF` maps the explicit cleared value `''` to NULL too.
Either way the comparison is NULL — not TRUE — so **no rows match**. RLS fails closed by construction, not by
anyone remembering to set something.

`WITH CHECK` carries the same predicate, so cross-tenant *writes* are rejected as well. `USING` alone would let
a tenant insert rows attributed to another and merely be unable to read them back.

`ALTER TABLE … FORCE ROW LEVEL SECURITY` is set on every tenant table, because policies otherwise do not apply
to the table's owner — which is exactly who runs migrations.

### Level 3 — Expert

Four things that are easy to get wrong and are handled explicitly:

**1. Superusers bypass RLS unconditionally.** Not "usually" — always, regardless of `ENABLE`/`FORCE`. An
isolation suite run on a superuser connection passes while proving nothing. `db/roles.sql` creates
`nexus_app`/`nexus_ro` with `NOSUPERUSER NOBYPASSRLS`, and
`RowLevelSecurity.assert_enforceable!` inspects `pg_roles` for the *current* connection and raises rather than
allow a meaningless assertion. See [SEC-001](../../security/findings.md).

**2. `INSERT … RETURNING` is governed by the read policy.** `RETURNING` reads the row back, and reads follow
`USING`, not `WITH CHECK`. PostgreSQL reports both failures with the identical message
(`new row violates row-level security policy`), so the error points at the wrong clause. This is why tenant
provisioning generates the organization's UUID application-side and sets the context to it *before* inserting —
turning bootstrap into an ordinary tenant-scoped write with no exemption policy at all. See
[SEC-003](../../security/findings.md).

**3. `SET LOCAL` is transaction-scoped.** Outside a transaction PostgreSQL emits a warning and discards it.
Using `SET LOCAL` rather than `SET` is deliberate: on a pooled connection, a plain `SET` would leak one
request's tenant into the next request that reuses that connection — a quiet and devastating failure.

**4. RLS cannot catch a mis-routed connection.** If the resolver hands you tenant B's connection while the
request is for tenant A, RLS happily enforces B. `verify_consistency!` reads the session variable back and
refuses to proceed on a mismatch — the backstop [ADR-009](../../11-decisions/ADR-009-multi-tenancy.md) calls
for, since the resolver is security-critical code.

---

## Data model

| Table | Tenant-scoped? | Notes |
|-------|----------------|-------|
| `organizations` | **Is** the tenant | Policy keys on `id`, not a self-referential `organization_id` |
| `memberships` | Yes | The user ↔ tenant link; roles are held *through* it |
| `teams`, `team_memberships` | Yes | |
| `org_placements` | Yes | Audit trail for pool → dedicated promotions |
| `users` | **No — global** | One human may belong to several tenants; per-tenant duplicates break SSO identity. Access is mediated by `memberships`, which *is* scoped |
| `regions`, `feature_flags` | No — platform-global | Enumerated in `config/ownership.yml` |

`organizations` carries a CHECK constraint tying `tier` to `database_key`: a dedicated tenant without a key is
unroutable, and a pool tenant with one is ambiguous.

## Published contract

| Operation | Purpose |
|-----------|---------|
| `Organizations::ProvisionOrganization` | Create a tenant, atomically, with its system roles |
| `Organizations::Tenant` | Tenant lookup (query) |
| `Organizations::Membership` | Membership lookup (query) |
| `Organizations::Placement` | Tier/region placement |

Provisioning delegates role creation to `Authorization::SeedSystemRoles` — `roles` belongs to Authorization,
and `boundary-check` caught the original direct insert. The fix published a capability instead of widening
a rule.

## Verification

`spec/isolation/tenant_isolation_spec.rb` — 10 examples covering: the enforceability guard, all three layers
active, layer (c) removed, layers (b) *and* (c) removed (database alone), cross-tenant write rejection,
connection/context mismatch, and nested-context switching.

**Proven non-vacuous by mutation:** `ALTER TABLE memberships DISABLE ROW LEVEL SECURITY` turns the suite red
with *"RLS failed to contain a query that bypassed application scoping"*; re-enabling turns it green.

## Related

[ADR-009](../../11-decisions/ADR-009-multi-tenancy.md) · [Security findings](../../security/findings.md) ·
[Tenant isolation](../../08-security/tenant-isolation.md) · [Context map](../../02-architecture/context-map.md)
