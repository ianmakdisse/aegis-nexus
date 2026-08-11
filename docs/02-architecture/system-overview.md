# System Overview

> The navigation spine of the architecture documentation. Six abstraction levels, each answering a different
> question, each linking down to the next. A developer should be able to descend from "what does the business
> do" to "which file" without ever guessing.

---

## Abstraction levels

| Level | Question it answers | Where |
|-------|--------------------|-------|
| **0 — Business** | What capabilities does the company sell? | [below](#level-0--business-architecture) · [business domains](../01-product/business-domains.md) |
| **1 — System context** | What is inside the system, what is outside, who talks to it? | [below](#level-1--system-context) |
| **2 — Containers** | What deployable units exist and why? | [below](#level-2--containers) · [container diagram](container-diagram.md) |
| **3 — Components** | What is inside a container? | [component diagram](component-diagram.md) |
| **4 — Runtime** | What actually happens when something occurs? | [request flow](request-flow.md) · [event flow](event-flow.md) · [data flow](data-flow.md) |
| **5 — Code** | Which directory, which file? | [codebase navigation](../00-start-here/codebase-navigation.md) |

---

## Level 0 — Business architecture

```mermaid
flowchart TB
    subgraph Value["Value delivered"]
        V1[Decisions made<br/>faster and consistently]
        V2[Work executed<br/>reliably across systems]
        V3[Everything provable<br/>after the fact]
        V4[AI deployed<br/>without unbounded risk]
    end

    subgraph Cap["Capabilities that deliver it"]
        C1[Capture]:::cap --> C2[Decide]:::cap --> C3[Act]:::cap --> C4[Prove]:::cap
        C5[Govern]:::cap
    end

    C1 -.-> V2
    C2 -.-> V1
    C3 -.-> V2
    C4 -.-> V3
    C5 -.-> V4

    classDef cap fill:#1e3a5f,stroke:#60a5fa,color:#e5e7eb
```

| Capability | Means | Bounded contexts |
|-----------|-------|------------------|
| **Capture** | Ingest what happened, durably, exactly once in effect | Integrations, Events |
| **Decide** | Apply policy, rules, and AI judgment within limits | Workflows, Agents, Documents |
| **Act** | Execute across systems with retries and compensation | Workflows, Integrations, Notifications |
| **Prove** | Reconstruct any decision and its inputs | Audit, Events |
| **Govern** | Enforce identity, permission, budget, and residency | Identity, Organizations, Authorization, Billing |

---

## Level 1 — System context

```mermaid
flowchart LR
    subgraph People
        U1[Operations lead]
        U2[Automation engineer]
        U3[Approver]
        U4[Compliance / FinOps]
    end

    NEXUS{{Aegis Nexus}}

    subgraph Upstream["Systems that send us facts"]
        E1[ERP · CRM · E-commerce]
        E2[Payments · Banks]
        E3[Logistics · IoT]
        E4[Internal services]
    end

    subgraph Downstream["Systems we act upon"]
        D1[Same systems, via APIs]
        D2[Slack · Email · WhatsApp]
    end

    subgraph Providers["Platform dependencies"]
        P1[AI model providers]
        P2[Identity providers OIDC/SAML]
        P3[Object storage]
        P4[Observability backend]
    end

    People <-->|HTTPS · WebSocket| NEXUS
    Upstream -->|signed webhooks · polling| NEXUS
    NEXUS -->|authenticated API calls| Downstream
    NEXUS <-->|model inference| P1
    NEXUS <-->|SSO| P2
    NEXUS <-->|documents| P3
    NEXUS -->|OTLP| P4

    classDef nx fill:#1e3a5f,stroke:#60a5fa,color:#e5e7eb,font-weight:bold
    class NEXUS nx
```

**Trust posture toward each edge** — the single most important thing to understand at this level:

| Edge | Trusted? | Consequence in the design |
|------|----------|---------------------------|
| Inbound webhooks | **No** | Signature + timestamp + idempotency before anything else (FR-201) |
| Uploaded documents | **No — actively hostile** | Malware scan, sanitization, and untrusted-content framing (FR-504, INV-19) |
| Model provider output | **No** | Data, never instruction (INV-19); tool proposals are authorized before execution (INV-20) |
| Downstream systems | **No** | Timeouts, circuit breakers, compensations; their slowness is not our outage |
| Internal services | **No** | Zero trust (INV-17) — network position is not a credential |
| Human users | **Authenticated, not trusted** | Deny-by-default authorization on every action (INV-15) |

---

## Level 2 — Containers

One image, several roles ([ADR-001](../11-decisions/ADR-001-architecture-style.md)). "Container" here means
*deployable unit*, not "Docker image".

```mermaid
flowchart TB
    subgraph Edge
        LB[Ingress / WAF]
    end

    subgraph Roles["Control plane — one image, N roles"]
        API[role: api<br/>REST · WebSocket]
        ING[role: ingest<br/>webhook receive]
        REL[role: relay<br/>outbox → backbone]
        CON[role: consumer<br/>backbone → handlers]
        PRJ[role: projector<br/>events → read models]
        WRK1[role: worker:default<br/>steps · timers · retries]
        WRK2[role: worker:agents<br/>AI executions]
        WRK3[role: worker:documents<br/>ingestion pipeline]
        SCH[role: scheduler<br/>timers · maintenance]
    end

    subgraph Data
        PG[(PostgreSQL<br/>authoritative)]
        RD[(Redis<br/>cache · locks · pubsub)]
        OS[(Object storage)]
        KF[(Kafka)]
    end

    WEB[React SPA]

    WEB --> LB --> API
    LB --> ING
    API --> PG
    API --> RD
    ING --> PG
    REL --> PG
    REL --> KF
    KF --> CON
    CON --> PG
    PRJ --> PG
    PRJ --> RD
    RD -.pubsub.-> API
    WRK1 --> PG
    WRK2 --> PG
    WRK3 --> PG
    WRK3 --> OS
    SCH --> PG

    classDef role fill:#1e3a5f,stroke:#60a5fa,color:#e5e7eb
    class API,ING,REL,CON,PRJ,WRK1,WRK2,WRK3,SCH role
```

| Role | Scaling driver | Why it is separate |
|------|---------------|--------------------|
| `api` | Request rate | Latency-critical; must not share a process with batch work |
| `ingest` | Webhook rate | Extreme rate, trivial work; isolated so a webhook storm cannot slow the API |
| `relay` | Outbox depth | Must keep publishing during load spikes; starving it silently delays everything downstream |
| `consumer` | Backbone lag | Scales with partition count |
| `projector` | Event volume | Isolated so a slow rebuild never touches the write path |
| `worker:default` | Queue depth | General step execution |
| `worker:agents` | Concurrency | Latency-bound on providers, not CPU-bound — needs a different concurrency model |
| `worker:documents` | Queue depth | Memory- and CPU-heavy; hostile input; a pre-authorized extraction candidate |
| `scheduler` | Fixed (leader-elected) | Singleton semantics; must not scale horizontally |

---

## Level 3 — Components

See [component diagram](component-diagram.md). Summary of the layering inside the control plane:

```
app/
├── interfaces/          HTTP controllers, WebSocket channels, webhook receivers, serializers
├── domains/             One directory per bounded context (INV-01/INV-02)
│   └── <context>/
│       ├── *.rb         PUBLIC contract — commands, queries, events
│       └── internal/    PRIVATE — aggregates, services, projections, adapters
└── infrastructure/      Cross-cutting mechanisms owned by no domain:
                         tenancy, event_store, events (outbox/inbox/transport),
                         jobs, projections, authorization plumbing, telemetry, cache
```

The `interfaces` layer never contains business logic; the `infrastructure` layer never contains domain
vocabulary. Both rules are checkable and are checked.

---

## Level 4 — Runtime behavior

| Scenario | Diagram |
|----------|---------|
| A request enters and is authorized | [request flow](request-flow.md) |
| An event travels from webhook to UI | [event flow](event-flow.md) |
| A workflow executes, suspends, and resumes | [workflow runtime](../03-domains/workflows/runtime.md) |
| An agent decides and calls tools | [agent runtime](../05-ai/agent-runtime.md) |
| A document becomes retrievable | [RAG](../05-ai/rag.md) |
| Something fails and recovers | [failure recovery](../04-distributed-systems/failure-recovery.md) |

The canonical UC-01 scenario is traced end-to-end in [use cases](../01-product/use-cases.md#uc-01--high-value-order-requires-governed-decisioning-canonical).

---

## Level 5 — Code

[Codebase navigation](../00-start-here/codebase-navigation.md) maps every subsystem to its entry point, public
API, internal components, tables, events emitted and consumed, jobs, and tests.

---

## The five properties everything is designed around

If you remember nothing else from this document:

1. **Nothing important lives only in memory.** Durable state or it did not happen (INV-07).
2. **Nothing important is written twice.** State and its event commit together (INV-04).
3. **Nothing important happens without a tenant.** Missing tenant context fails closed (INV-14).
4. **Nothing important happens without authorization.** Including — especially — when an AI asked for it (INV-15, INV-20).
5. **Nothing important is unexplainable afterwards.** Trace it, audit it, replay it (INV-21, INV-23).
