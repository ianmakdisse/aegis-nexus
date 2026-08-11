# Security Findings Register

> Every finding is tracked to closure **with a regression test** (NFR-305). A finding closed without a test is
> not closed; it is forgotten.
>
> Findings are recorded whether they came from a review, a tool, an incident, or someone noticing something
> odd during development. The register's value is proportional to how uncomfortable it is to write in.

**Severity:** `CRITICAL` exploitable now, data at risk · `HIGH` exploitable with conditions ·
`MEDIUM` defense-in-depth gap · `LOW` hardening

---

## SEC-001 — Isolation suite would have passed on a connection that bypasses RLS

| | |
|---|---|
| **Severity** | **HIGH** (as a *verification* defect; no data was at risk) |
| **Status** | ✅ Fixed + regression guard |
| **Found** | 2026-08-10, Phase 3, during the first execution of the RLS proof |
| **Component** | `infrastructure/database/row_level_security.rb`, `db/roles.sql`, isolation suite |
| **Requirement** | [FR-102](../01-product/requirements.md#fr-102), [INV-14](../02-architecture/architecture-constitution.md#inv-14--tenant-isolation-is-enforced-at-three-independent-layers) |

### What happened

The first run of the tenant-isolation check queried `organizations` with **no tenant context set** and returned
**2 rows**. It should have returned 0.

Root cause: the connection was a PostgreSQL **superuser**, and superusers bypass Row-Level Security
unconditionally — `ENABLE`/`FORCE ROW LEVEL SECURITY` and the policies themselves are simply not consulted.

### Why this is worth a HIGH

No production data was exposed; the defect was in *verification*, not in the product. But the failure mode is
the worst kind:

- The isolation suite would have run green **forever**.
- It would have reported success while never once executing the comparison it exists to make.
- Local development and CI both commonly run as a superuser, so this would not have been caught by "it works
  on my machine" or by CI passing.
- The team's confidence in isolation would have been based on a test that could not fail.

A test that cannot fail is worse than no test, because it is trusted.

### Attack scenario

Not directly attacker-triggerable. The realistic path is organizational: an application bug omits a tenant
filter, the isolation suite does not catch it because the suite is inert, and the bug reaches production where
the app role *does* have RLS applied — or worse, where an operator has "temporarily" granted elevated
privileges to debug something.

### Remediation

1. **Least-privilege roles** (`db/roles.sql`): `nexus_app` and `nexus_ro`, both created with
   `NOSUPERUSER NOBYPASSRLS`, holding DML-only grants. The application never connects as the schema owner.
2. **A guard that refuses to be fooled** — `RowLevelSecurity.assert_enforceable!` inspects
   `pg_roles.rolsuper` / `rolbypassrls` for the *current connection* and raises
   `NotEnforceable` rather than allowing an isolation assertion to be made on a connection that cannot deny.
3. The isolation suite calls that guard **before** any assertion, so the suite fails loudly on a mis-configured
   connection instead of passing quietly.

### Regression test

`spec/isolation/tenant_isolation_spec.rb` — the first example asserts `assert_enforceable!` passes, and the
suite aborts if it does not. Re-introducing a superuser connection turns the suite red immediately.

### Verified

All seven RLS behaviors re-verified on a `nexus_app` connection: no context ⇒ 0 rows; unknown tenant ⇒ 0 rows;
cleared context ⇒ 0 rows (not a cast error); correct tenant ⇒ exactly its own rows; cross-tenant `INSERT`
rejected by `WITH CHECK`; correctly-attributed `INSERT` succeeds; the other tenant cannot see it.

### Lesson recorded

> A security control that is *configured* is not a security control that is *enforced*. Prove the control can
> deny before trusting any test that assumes it does.

This generalizes beyond RLS and is now a review question for every isolation-style control the platform adds.

---

## SEC-002 — `db/roles.sql` silently skipped its grants

| | |
|---|---|
| **Severity** | LOW (fail-closed; caused a visible error, not a leak) |
| **Status** | ✅ Fixed |
| **Found** | 2026-08-10, immediately after SEC-001 |
| **Component** | `db/roles.sql` |

`GRANT CONNECT ON DATABASE CURRENT_CATALOG` is not valid syntax. Combined with `ON_ERROR_STOP`, the script
aborted at that line and **every subsequent GRANT was skipped**, which surfaced later as an opaque
`permission denied for table organizations`.

Fixed by using psql's `:"DBNAME"` variable, with a comment explaining the failure mode so the next person does
not spend the same twenty minutes. Noted here because the *shape* of the bug — a setup script that
half-succeeds and leaves the system in a state whose error message points somewhere else — is worth
recognizing, and because it failed in the safe direction.

---

## SEC-003 — `INSERT … RETURNING` is governed by the read policy, not the write policy

| | |
|---|---|
| **Severity** | MEDIUM (design defect; failed closed, so no exposure) |
| **Status** | ✅ Fixed — the special case was removed rather than patched |
| **Found** | 2026-08-10, Phase 3, first run of the isolation suite |
| **Component** | `db/migrate/*_enable_row_level_security.rb`, `domains/organizations/provision_organization.rb` |
| **Requirement** | [FR-101](../01-product/requirements.md#fr-101), INV-14 |

### What happened

Tenant provisioning needs to insert an `organizations` row *before* that tenant's context can exist. The
original design added a second, narrowly-scoped policy:

```sql
CREATE POLICY organizations_provisioning ON organizations
  FOR INSERT WITH CHECK (current_setting('nexus.provisioning', true) = 'on');
```

It did not work, and the way it failed is the interesting part. A bare `INSERT` was accepted. The same
`INSERT … RETURNING id` — which ActiveRecord *always* emits — was rejected with:

```
ERROR:  new row violates row-level security policy for table "organizations"
```

Identical message, different cause. `RETURNING` must read the row back, and reads are governed by the
**`USING`** clause. A `FOR INSERT` policy has no `USING` clause, and the tenant policy's `USING` evaluated to
NULL because no tenant was set. **The write was permitted; the read-back was not.**

### Why it cost time

Every signal pointed at the write path: the error names `WITH CHECK` semantics, the flag was verifiably set
(`current_setting` returned `'on'` immediately before the failing statement), and the identical statement
succeeded in `psql` — because the hand-typed version omitted `RETURNING`.

### Remediation — remove the special case

The obvious fix was a matching `FOR SELECT` exemption. That was rejected: it would make **every**
organization readable for the duration of any provisioning transaction, to solve a self-inflicted problem.

Instead, the organization's UUID is now generated by the application, the tenant context is set to it *before*
the `INSERT`, and provisioning became an ordinary tenant-scoped write that the existing policy already permits:

```ruby
organization_id = SecureRandom.uuid
Tenancy::Context.with(organization_id: organization_id) do
  Database::RowLevelSecurity.apply!          # SET LOCAL nexus.organization_id = <new id>
  Organization.create!(id: organization_id, ...)   # WITH CHECK ✓ and USING ✓
end
```

Net result: **one policy instead of two, no exemption, no session flag, and no window in which the tenant
policy is not the only rule in force.** The bootstrap path now runs through exactly the same isolation layers
as every other write.

### Regression test

`spec/isolation/tenant_isolation_spec.rb` — provisioning runs through the public contract in every example, so
a reintroduced exemption or a broken bootstrap fails the whole suite. Verified non-vacuous by mutation:
`ALTER TABLE memberships DISABLE ROW LEVEL SECURITY` turns the suite red with
*"RLS failed to contain a query that bypassed application scoping"*, and re-enabling turns it green.

### Lessons recorded

1. **`INSERT … RETURNING` needs both `WITH CHECK` and `USING` to pass.** Any RLS policy written for a
   framework that returns inserted rows must account for read visibility, not only write permission.
2. **PostgreSQL reports both failures with the same message.** When an RLS error contradicts the evidence,
   check whether the statement reads anything back.
3. **A special case that needs an exemption is usually the wrong shape.** Removing the need for the exemption
   produced a smaller and safer design than granting one would have.

---

## Open findings

_None._

## Register conventions

| Field | Purpose |
|-------|---------|
| Severity | As defined above; downgrade only with a written reason |
| Attack scenario | Concrete. "An attacker could do something bad" is not a scenario |
| Remediation | What changed, not what should change |
| Regression test | The specific test. Mandatory for closure |
| Lesson | Only when it generalizes — otherwise omit rather than pad |
