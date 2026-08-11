# Container Diagram (Level 2)

> "Container" = **independently deployable and scalable unit**, not "Docker image". There is exactly one image
> ([ADR-001](../11-decisions/ADR-001-architecture-style.md)); the roles below are that image started with a
> different `NEXUS_ROLE`.
>
> Level 1 (context) and the reasoning behind this split: [system overview](system-overview.md).

---

## The deployable units

```mermaid
flowchart TB
    subgraph Clients
        SPA[React SPA]
        EXT[External systems]
        CLI[API clients]
    end

    subgraph Edge
        WAF[Ingress · WAF · TLS termination]
    end

    subgraph CP["Control plane — one image, nine roles"]
        direction TB
        API["**api**<br/>REST + WebSocket<br/>scales on request rate"]
        ING["**ingest**<br/>webhook receipt only<br/>scales on webhook rate"]
        REL["**relay**<br/>outbox → backbone<br/>scales on outbox age"]
        CON["**consumer**<br/>backbone → handlers<br/>scales on consumer lag"]
        PRJ["**projector**<br/>events → read models<br/>scales on projection lag"]
        WD["**worker:default**<br/>steps · timers · retries<br/>scales on queue depth"]
        WA["**worker:agents**<br/>AI executions<br/>scales on concurrency"]
        WDOC["**worker:documents**<br/>ingestion pipeline<br/>memory-heavy"]
        SCH["**scheduler**<br/>due-time dispatch<br/>singleton, leader-elected"]
    end

    subgraph Data
        PG[("PostgreSQL 16<br/>+ pgvector<br/>**authoritative**")]
        PGR[("Read replica")]
        RD[("Redis<br/>cache · locks · pub/sub")]
        KF[("Kafka<br/>transport only")]
        OS[("Object storage")]
    end

    subgraph Ext["External"]
        AI[Model providers]
        IDP[OIDC / SAML]
        OTEL[Telemetry backend]
        TGT[Customer systems]
    end

    SPA & CLI --> WAF --> API
    EXT -->|signed webhooks| WAF --> ING

    API --> PG
    API --> RD
    API -.reads.-> PGR
    ING --> PG

    REL --> PG
    REL --> KF
    KF --> CON
    CON --> PG
    PRJ --> PG
    PRJ --> RD
    RD -.pub/sub.-> API

    WD --> PG
    WD --> TGT
    WA --> PG
    WA --> AI
    WDOC --> PG
    WDOC --> OS
    SCH --> PG

    API --> IDP
    CP --> OTEL

    classDef role fill:#1e3a5f,stroke:#60a5fa,color:#e5e7eb
    classDef store fill:#0f2b1e,stroke:#34d399,color:#e5e7eb
    class API,ING,REL,CON,PRJ,WD,WA,WDOC,SCH role
    class PG,PGR,RD,KF,OS store
```

---

## Why each role is separate

A role exists when it has a **different scaling signal** or a **different failure containment need**. Splitting
on any other basis just multiplies pods.

| Role | Separate because | If it were merged into `api` |
|------|------------------|------------------------------|
| `ingest` | Extreme request rate, near-zero logic | A webhook storm would consume the threads serving interactive users |
| `relay` | Must keep publishing under load; failure is *silent* | Under API load, publication would starve and every downstream automation would silently lag |
| `consumer` | Scales with partitions, not requests | Consumer rebalances would stall API threads |
| `projector` | Rebuilds are long and bursty | A rebuild would compete with p95-sensitive traffic |
| `worker:agents` | Latency-bound (seconds), not CPU-bound | 25 blocked threads per pod would need 25 API threads too |
| `worker:documents` | Memory-heavy, hostile input | A parser OOM would take down request serving |
| `scheduler` | Singleton semantics | N API pods would each fire every timer |

## Concurrency models differ per role

Worth stating because it is the most common sizing mistake:

| Role | Bound by | Threads/pod | Sizing driver |
|------|----------|-------------|---------------|
| `api` | CPU + DB latency | ~8 | Connection pool budget |
| `worker:agents` | **Waiting on a network call** | ~25 | Provider concurrency limits, not CPU |
| `worker:documents` | Memory + CPU | ~4 | Peak per-document memory |
| `relay` | DB write throughput | ~4 | Batch size × publish latency |

`worker:agents` running the same thread count as `api` would waste roughly two thirds of its capacity sitting
in `read()` — which is precisely why it is a separate role rather than a queue on a shared worker.

## Connection budgets

Every role draws from the same PostgreSQL connection ceiling, so budgets are assigned rather than assumed
(the mitigation named in [ADR-001](../11-decisions/ADR-001-architecture-style.md)):

```
PgBouncer (transaction pooling)
 ├── api             40%   latency-critical, must never be starved
 ├── workers         35%
 ├── consumer+relay  15%   starving these is silent, so they get a floor
 ├── projector        7%
 └── scheduler        3%
```

Without per-role budgets, a worker autoscale event exhausts the pool and the API returns 500s for a reason that
has nothing to do with the API.

## Deployment properties

| Property | Value |
|----------|-------|
| Image | One, built once per commit; roles differ only by `NEXUS_ROLE` |
| Migrations | A separate job (`NEXUS_ROLE=migrate`), never an app-boot side effect (INV-11) |
| Rollout order | Workers and consumers first, `api` last — N/N+1 compatibility makes the mixed state safe |
| Drain | SIGTERM → finish or release leases; `tini` forwards the signal |
| Probes | Every role answers `/healthz`, including non-HTTP roles |

## Related

[Component diagram](component-diagram.md) (level 3) · [Deployment architecture](deployment-architecture.md) ·
[`config/roles.yml`](../../apps/control-plane/config/roles.yml) · [Failure domains](failure-domains.md)
