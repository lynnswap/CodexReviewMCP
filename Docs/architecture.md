# Architecture

CodexReviewMCP exposes Codex review as MCP tools and as a small macOS monitor app. The main design goal is to keep application state and review workflow rules independent from live processes, files, and MCP transport details.

## Overview

```mermaid
flowchart
    subgraph Codex["Codex"]
        CodexAppServer["app-server"]
    end

    subgraph DataSources["Data sources"]
        direction TB
        AppServer["App-server adapter<br/>review / auth / settings"]
        Platform["Platform adapter<br/>runtime registry / system client"]

        AppServer ~~~ Platform
    end

    subgraph Model["Model"]
        direction LR
        StoreProtocol["ReviewStoreProtocol<br/>session-aware intents"]
        Store["CodexReviewStore<br/>source of truth"]
        State["Application state<br/>auth / settings / workspace / job"]
        Workflows["Workflows<br/>review / auth / settings / server"]
        Ports["ReviewPorts<br/>ReviewEngine / Store / Tool protocols"]
    end

    subgraph Interface["Interface"]
        direction TB
        subgraph UI["UI layer"]
            Views["Views / ViewControllers"]
        end
        subgraph Adapters["Tool adapters"]
            MCP["MCP boundary"]
            CLI["CLI boundary"]
            ToolProtocol["ReviewToolProtocol<br/>review_start / read / list / cancel"]
        end
    end

    MCP --> ToolProtocol
    CLI --> ToolProtocol
    ToolProtocol --> StoreProtocol

    StoreProtocol --> Store
    Store -->|direct observation| Views
    Store --> State
    Store --> Workflows
    State --> Workflows
    Workflows --> Ports

    Ports --> AppServer
    AppServer --> CodexAppServer
    AppServer --> Platform
```

## Layers

| Layer | Responsibility |
| --- | --- |
| Interface | UI rendering plus MCP/CLI boundaries that send user or tool intents into the model |
| Model | `ReviewApplication` state, source-of-truth store, workflows, and protocol boundaries |
| Data sources | Live adapters and platform primitives that isolate external effects from the model |
| Codex | Codex-owned `app-server` process used by the app-server adapter |
| Domain values | Pure request, response, settings, account, job, and cancellation values shared across layers |

## Design Principles

- UI observes concrete application state directly. There is no ViewModel or mirror-state layer for rendering.
- MCP and CLI tool calls are converted into session-scoped application intents.
- Review execution side effects are hidden behind protocol boundaries, so workflows do not know app-server or file-system details.
- Live runtime wiring is centralized around the monitor/server runtime instead of being spread through UI or workflow code.
- Domain values stay pure and portable across UI, MCP, runtime, and app-server integration code.

## Review Flow

```mermaid
sequenceDiagram
    participant Client as MCP client
    participant Adapter as ReviewMCPAdapter
    participant Store as CodexReviewStore
    participant Workflow as ReviewApplication workflow
    participant Engine as ReviewEngine
    participant AppServer as codex app-server

    Client->>Adapter: review_start
    Adapter->>Store: startReview(sessionID, request)
    Store->>Workflow: enqueue and run review
    Workflow->>Engine: runReview(request)
    Engine->>AppServer: thread/start and review/start
    AppServer-->>Engine: events and final result
    Engine-->>Workflow: outcome
    Workflow-->>Store: mutate observable job state
    Store-->>Adapter: ReviewReadResult
    Adapter-->>Client: structured MCP result
```

## Runtime State

ReviewMCP uses `~/.codex_review` as its dedicated Codex home for backend config
and runtime metadata. The shared `codex app-server` launched by ReviewMCP uses
the same home.
