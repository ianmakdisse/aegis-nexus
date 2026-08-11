# docs-lint

Documentation consistency checker. Enforces
[INV-26](../../docs/02-architecture/architecture-constitution.md#inv-26--documentation-is-part-of-the-change):
*documentation is part of the change*.

```bash
ruby tools/docs-lint/lint.rb                    # all checks
ruby tools/docs-lint/lint.rb --strict           # warnings are fatal too
ruby tools/docs-lint/lint.rb --only=broken-link
ruby tools/docs-lint/lint.rb --format=json
```

Exit code is non-zero when there are errors (or, with `--strict`, any findings).

## Why this exists

Documentation rots silently. Nobody notices a link that stopped resolving three
refactors ago until a new engineer follows it at 2 a.m. and concludes the docs
cannot be trusted — at which point the entire `/docs` investment is worthless,
because a documentation set is only as credible as its least accurate page.

Making it a build failure is the only mechanism that has ever worked.

## Rules

| Rule | Severity | Detects |
|------|----------|---------|
| `broken-link` | error | A relative link whose target does not exist and is not declared in `planned-docs.yml` |
| `broken-anchor` | error | A link to a heading that does not exist in the target file (suggests the closest match) |
| `stale-plan` | error | A document declared for a phase that has passed and still does not exist |
| `undeclared-plan` | warning | A planned document now exists but is still listed as planned |
| `missing-code` | warning | A path in a "Related code" section does not exist in the repository |
| `orphan` | warning | A document nothing links to |

## Forward references and `planned-docs.yml`

Architecture documents are written *before* the system they describe
([INV-25](../../docs/02-architecture/architecture-constitution.md#inv-25--significant-architectural-decisions-have-an-adr-written-before-implementation)),
so they necessarily link to documents that do not exist yet. A naive link
checker makes that impossible; suppressing the check makes it meaningless.

`planned-docs.yml` is the middle path: a forward reference is legal **only if
declared**, with the phase that will create it.

```yaml
planned:
  - path: docs/05-ai/rag.md
    phase: 9
```

Two rules stop this becoming a permanent excuse list:

1. When the file appears, the entry must be removed (`undeclared-plan`).
2. When `config.yml:current_phase` passes the entry's phase and the file still
   does not exist, it becomes an **error** (`stale-plan`).

So the manifest can only ever shrink or block the build. Bump `current_phase`
in `config.yml` as each phase completes — that is what arms the second rule.

## Anchors

Headings are slugged with GitHub's algorithm. For **stable identifiers**
(requirement IDs, invariant IDs) prefer an explicit anchor so that editing the
heading prose never breaks inbound links:

```markdown
<a id="fr-101"></a>
### FR-101 — Tenant as the root isolation unit
```

Both forms are recognized.

## CI

Runs on every pull request; see [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml).

## Related

- [`tools/boundary-check`](../boundary-check/README.md) — the equivalent enforcement for code boundaries
- [Architecture Constitution](../../docs/02-architecture/architecture-constitution.md)
