# Aegis Nexus

**Autonomous distributed operations and intelligence platform.** It sits between a company's systems, its
people, and a fleet of AI agents — turning events into governed decisions, durable workflows, human approvals,
and auditable actions.

> **New here? → [docs/00-start-here/README.md](docs/00-start-here/README.md)**
> **Want to know what's actually built? → [docs/00-start-here/project-state.md](docs/00-start-here/project-state.md)**

---

## Repository layout

```
aegis-nexus/
├── docs/                      The engineering knowledge base — a deliverable, not a courtesy
│   ├── 00-start-here/         Entry point, glossary, project state
│   ├── 01-product/            Requirements (FR/NFR), personas, use cases
│   ├── 02-architecture/       Constitution, context map, system overview, failure domains
│   ├── 03-domains/ … 10-…     Per-subsystem deep dives
│   ├── 11-decisions/          ADRs — why anything is the way it is
│   ├── 12-operations/         Runbooks, deployment, incident response
│   └── 13-reference/          API, events, schema, configuration
├── apps/
│   └── control-plane/         Rails modular monolith, run under several process roles
│       ├── app/               Delivery: controllers, channels, serializers
│       ├── domains/           Bounded contexts (Nexus::*) — the business
│       ├── infrastructure/    Cross-cutting mechanisms (Nexus::*)
│       ├── config/
│       │   ├── ownership.yml  Machine-readable context boundaries
│       │   └── roles.yml      Process roles and their scaling signals
│       └── db/
├── infra/                     Docker, Kubernetes, Helm, Terraform
└── tools/
    ├── docs-lint/             Documentation consistency (CI-blocking)
    ├── boundary-check/        Module boundary enforcement (CI-blocking)
    └── migration-lint/        Rolling-deploy + tenancy safety for migrations (CI-blocking)
```

## Quick start

```bash
# Constitutional checks — no dependencies beyond Ruby
ruby tools/docs-lint/lint.rb            # documentation consistency
ruby tools/boundary-check/check.rb      # module boundaries
ruby tools/migration-lint/lint.rb       # rolling-deploy + tenancy safety
./tools/boundary-check/self-test.sh     # prove the checkers still detect violations
./tools/migration-lint/self-test.sh

# Control plane
cd apps/control-plane
bundle install
bundle exec rails zeitwerk:check        # autoloading is sane
bundle exec rails db:prepare            # needs PostgreSQL
NEXUS_ROLE=api bundle exec rails server
```

Roles are selected with `NEXUS_ROLE` — see [`config/roles.yml`](apps/control-plane/config/roles.yml).

## The twelve decisions that shape everything

| | Decision | Why |
|---|----------|-----|
| [001](docs/11-decisions/ADR-001-architecture-style.md) | Modular monolith, independently scaled roles | The requirement was independent *scaling*, not independent *deployment* |
| [002](docs/11-decisions/ADR-002-database.md) | PostgreSQL as the single authoritative store | One transaction boundary makes the outbox structural, not protocol-based |
| [003](docs/11-decisions/ADR-003-event-bus.md) | Kafka for the log, DB queue for scheduling | They are different problems with incompatible optimal solutions |
| [004](docs/11-decisions/ADR-004-cqrs.md) | CQRS per context, not globally | Authorization must stay strongly consistent |
| [005](docs/11-decisions/ADR-005-event-sourcing.md) | Event sourcing for exactly four aggregates | Used where history *is* the requirement; harmful for credentials |
| [006](docs/11-decisions/ADR-006-workflow-engine.md) | Build the durable workflow engine | Workflows are tenant-authored data, not deployed code |
| [007](docs/11-decisions/ADR-007-ai-runtime.md) | Own the agent loop, abstract the provider | Governance must sit between every model turn and tool call |
| [008](docs/11-decisions/ADR-008-vector-database.md) | pgvector behind a port | RLS applies to vector queries automatically |
| [009](docs/11-decisions/ADR-009-multi-tenancy.md) | Hybrid RLS pool + dedicated tier | One codebase, two topologies |
| [010](docs/11-decisions/ADR-010-consistency-model.md) | Declared consistency per operation | Anything that can *deny* an action reads strong state |
| [011](docs/11-decisions/ADR-011-authentication.md) | Access tokens carry identity, never permissions | Identity may be briefly stale; authority may not |
| [012](docs/11-decisions/ADR-012-domain-schema.md) | Domain schema unpartitioned until the maintenance job exists | A partition does not inherit its parent's RLS policy |

## Non-negotiables

Five properties everything is designed around — the long form is the
[Architecture Constitution](docs/02-architecture/architecture-constitution.md):

1. Nothing important lives only in memory.
2. Nothing important is written twice (state and its event commit together).
3. Nothing important happens without a tenant.
4. Nothing important happens without authorization — especially when an AI asked for it.
5. Nothing important is unexplainable afterwards.

## Contributing

A change that alters documented behavior updates the documentation in the same pull request. This is enforced,
not requested — `docs-lint` and `boundary-check` are blocking CI jobs, and they are the mechanisms two ADRs
explicitly depend on. If you are about to make one non-blocking, you are changing the architecture: write an ADR.
