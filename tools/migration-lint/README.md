# migration-lint

Fails the build on a schema change that a rolling deploy would turn into an
outage, or that would leave a tenant table without isolation.

```bash
ruby tools/migration-lint/lint.rb            # check apps/control-plane
ruby tools/migration-lint/lint.rb --format=json
./tools/migration-lint/self-test.sh          # prove the linter still detects violations
```

Exit code is non-zero when anything is reported. It is a **blocking** CI job —
if it is ever downgraded to advisory,
[INV-11](../../docs/02-architecture/architecture-constitution.md#inv-11--schema-changes-are-safe-for-rolling-deployment)
goes back to being enforced by hope.

## Why it exists

A rolling deploy runs version N and version N+1 of the application **at the same
time, on purpose**. That single fact makes a set of ordinary-looking migrations
unsafe:

| You wrote | What actually happens |
|-----------|----------------------|
| `remove_column :orders, :legacy` | Version N still selects it. Every one of its queries fails until the deploy finishes. |
| `add_column :orders, :region, null: false` | Version N still inserts without it. Every insert fails. |
| `add_index :orders, :customer_id` | Postgres locks the table against writes for the whole index build. |
| `rename_column :orders, :a, :b` | Both versions are wrong at once. |

None of these look dangerous in review, which is why they are checked by a
machine. [TD-005](../../docs/technical-debt.md) recorded this gap as P1, due in
the phase where the first real domain migrations landed.

## Rules

| Rule | Invariant | Fails when |
|------|-----------|-----------|
| `destructive-ddl` | INV-11 | `drop_table`, `remove_column`, `rename_column`, `rename_table`, `remove_index`, `change_column_null`, or destructive raw SQL, without a declared prior expand |
| `not-null-without-default` | INV-11 | `add_column … null: false` with no default, on a table not created in the same migration |
| `blocking-index` | INV-11 | `add_index` on an existing table without `algorithm: :concurrently` |
| `missing-tenant-column` | INV-13 | `create_table` with no `organization_id`, for a table not in `ownership.yml:tenant_exempt` |
| `missing-tenant-index` | INV-13 | a tenant table where `organization_id` leads no index |
| `missing-rls` | INV-14 | a tenant table with no row-level security policy |

### Declaring a contract migration

Destructive DDL is legal once the expand and backfill have shipped in an
**earlier deploy**. Say which migration that was:

```ruby
class DropLegacyField < ActiveRecord::Migration[7.1]
  # expand-migration: 20260810000004
  def change
    remove_column :orders, :legacy_field, :string
  end
end
```

The named migration must exist and must be older. This is a human assertion on
purpose: the linter cannot know whether the intervening deploy actually
happened, and a tool that pretended to know would be worse than one that asks.

### Putting a table under RLS

```ruby
create_table :workflow_runs, id: :uuid do |t|
  t.uuid :organization_id, null: false
  ...
end
add_index :workflow_runs, %i[organization_id status]
enable_tenant_rls! :workflow_runs
```

`enable_tenant_rls!` comes from
[`lib/nexus/migration/tenancy.rb`](../../apps/control-plane/lib/nexus/migration/tenancy.rb)
and issues `ENABLE` + `FORCE` + the policy. `FORCE` is the clause people omit,
and omitting it makes RLS silently inert for the migration-running role — see
[SEC-001](../../docs/security/findings.md).

The Phase 3 bulk form (a `TENANT_TABLES = %w[…]` constant) is also recognized, so
the tool did not require editing a migration that has already been applied.
Editing applied migrations to satisfy a linter is a worse habit than the one
being enforced.

## What it cannot see

This is a text matcher, not a parser — the same trade
[boundary-check](../boundary-check/README.md) makes, for the same reason.

- DDL built by string interpolation or a computed table name
- Anything inside `execute` beyond a keyword scan
- Schema changes made outside `db/migrate`
- Whether a backfill actually ran, or whether the intervening deploy happened

A determined migration defeats it. It catches the realistic mistake, which is an
engineer writing an ordinary destructive migration without thinking about the
fifteen minutes during which two versions are live.

`def down` bodies are deliberately not linted: rollback code is destructive by
definition, and reporting it would teach people to disable the tool.

## Related

[Constitution INV-11, INV-13, INV-14](../../docs/02-architecture/architecture-constitution.md) ·
[ADR-002](../../docs/11-decisions/ADR-002-database.md) ·
[ADR-009](../../docs/11-decisions/ADR-009-multi-tenancy.md) ·
[boundary-check](../boundary-check/README.md) · [docs-lint](../docs-lint/README.md)
