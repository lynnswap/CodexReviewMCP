# Architecture Overview

作成日: 2026-05-02
更新日: 2026-05-04

このドキュメントは、CodexReviewMCP の現在のアーキテクチャと SwiftPM target 依存を GitHub Mermaid で俯瞰するためのメモです。

ここでの目的は、議論しやすい粒度で「何を中心に置き、何を外側へ出しているか」を見えるようにすることです。

## 全体像

この図では、各レイヤーが参照する protocol boundary を中心に描きます。矢印は target import ではなく、boundary の参照方向と実装関係です。live / test の差し替えは、この protocol の実装を入れ替えることで行います。SwiftPM target の実際の import 依存は後述の「Swift Package ターゲット依存」に分けて書きます。

```mermaid
flowchart TB
    subgraph Inputs["Input boundaries"]
        direction LR
        subgraph UI["UI layer"]
            ViewLayer["Views / ViewControllers"]
            StoreObservation["CodexReviewStore<br/>direct observation"]
        end

        subgraph Adapter["Interface adapters"]
            MCPBoundary["MCP boundary"]
            CLIBoundary["CLI boundary"]
            ToolPort["ReviewToolProtocol<br/>review_start / read / list / cancel"]
        end
    end

    subgraph App["ReviewApplication"]
        StoreProtocol["ReviewStoreProtocol<br/>session-aware intents"]
        Store["CodexReviewStore<br/>source of truth"]
        AppState["Application state<br/>auth / settings / workspace / job"]
        Workflows["Workflows<br/>ReviewWorkflow / AuthWorkflow / SettingsWorkflow / ServerWorkflow"]
        Dependencies["ReviewPorts<br/>ReviewEngine / Store / Tool protocols"]
    end

    subgraph Implementations["Live dependency targets"]
        direction LR
        subgraph Platform["ReviewPlatform"]
            RuntimeRegistryImpl["RuntimeRegistry implementation"]
            SystemClientImpl["SystemClient implementation"]
            Files["~/.codex_review"]
            Process["process / clock / file system"]
        end

        subgraph AppServer["ReviewAppServerAdapter"]
            ReviewEngineImpl["ReviewEngine implementation"]
            AuthSettingsImpl["auth / settings app-server clients"]
            Codex["codex app-server"]
        end
    end

    ViewLayer --> StoreObservation
    MCPBoundary --> ToolPort
    CLIBoundary --> ToolPort

    StoreObservation --> Store
    ToolPort --> StoreProtocol
    StoreProtocol --> Store
    Store --> AppState
    Store --> Workflows
    AppState --> Workflows
    Workflows --> Dependencies

    ReviewEngineImpl -.->|implements| Dependencies

    ReviewEngineImpl --> Codex
    AuthSettingsImpl --> Codex
    ReviewEngineImpl --> Platform
    AuthSettingsImpl --> Platform
    RuntimeRegistryImpl --> Files
    SystemClientImpl --> Process
```

読み方:

- UI layer は `ReviewApplication` の store/state を直接 observe します。ただし `CodexReviewStore` の生成や live dependency wiring は composition root に置き、UI から app-server adapter は見ません。
- MCP / CLI は `ReviewToolProtocol` を通じて store intent を呼びます。tool call の decode/encode と store intent の橋渡しに限定します。
- `ReviewApplication` の接続は、input adapter からは `ReviewToolProtocol -> ReviewStoreProtocol -> CodexReviewStore`、UI からは concrete `CodexReviewStore` の direct observation です。外側から workflow を直接触らせません。
- `ReviewStoreProtocol` は observable state の抽象ではなく、MCP / CLI から session-aware intent を呼ぶための境界です。
- workflow は app-server や file system の concrete 実装を知りません。
- `ReviewAppServerAdapter` は app-server 系 protocol の live 実装だけを持ちます。
- `ReviewPlatform` は runtime registry、clock、process、file system の live 実装だけを持ちます。
- `ReviewPorts` は `ReviewStoreProtocol`, `ReviewToolProtocol`, `ReviewEngine` などの cross-target protocol boundary を持ちます。auth / settings / server lifecycle の package protocol は `ReviewApplication` 内に残り、live wiring は `ReviewServiceRuntime` が担います。
- test 用実装は図に出していません。`ReviewEngine` などの境界実装を差し替える前提です。

### 対応表

| Area | 主な場所 | 役割 |
| --- | --- | --- |
| UI layer | `Sources/ReviewUI` | AppKit/SwiftUI の native rendering。`@Observable` state を直接 observe する |
| Interface adapters | `Sources/ReviewMCPAdapter` | MCP / HTTP/SSE / STDIO の入力を application intent に変換する |
| ReviewApplication | `Sources/ReviewApplication` | `@Observable` state、workflow、dependency boundary を持つ中心層 |
| ReviewPorts | `Sources/ReviewPorts` | `ReviewStoreProtocol`, `ReviewToolProtocol`, `ReviewEngine` などの cross-target protocol boundary |
| ReviewServiceRuntime | `Sources/ReviewServiceRuntime` | monitor app / server の live wiring と store factory |
| ReviewAppServerAdapter | `Sources/ReviewAppServerAdapter` | `codex app-server` との protocol、auth、config/read、review/start を扱う |
| ReviewPlatform | `Sources/ReviewPlatform` | discovery、runtime state、account files、clock/process/file system などの live dependency 実装 |
| ReviewDomain | `Sources/ReviewDomain` | request / response / settings / account key などの pure value |
| Composition roots | `Sources/ReviewCLI`, `Tools/CodexReviewMonitor` | application、adapter、live implementation を組み立てる |

設計上の注意点:

- 現在、`ReviewApplication` は `ReviewPlatform` / `ReviewAppServerAdapter` / `ReviewMCPAdapter` を import しません。
- review execution の外部副作用は `ReviewPorts` の `ReviewEngine` に閉じます。input adapter と store の接続は `ReviewToolProtocol` / `ReviewStoreProtocol` で扱います。
- live wiring は `ReviewServiceRuntime` と app / executable などの composition root に置きます。
- UI layer と app-server adapter は直接依存しません。
- `CodexReviewJob` / `CodexReviewWorkspace` などの observable state は `ReviewApplication` が持ちます。
- UI は `CodexReviewStore` / `CodexReviewWorkspace` / `CodexReviewJob` を直接 observe します。描画用 ViewModel や mirror state は追加しません。

## 境界別の詳細

全体図に concrete type を全部載せると読めなくなるため、詳細は protocol boundary ごとに分けます。

### UI と入力

この図の矢印は user/tool input が store intent に変換され、Observation で native UI に反映される流れです。target import 依存ではありません。

```mermaid
flowchart LR
    User["User action"] --> UI["ReviewUI"]
    MCPClient["MCP client"] --> MCP["ReviewMCPAdapter"]
    CLIUser["CLI invocation"] --> CLI["ReviewCLI"]

    UI --> StoreAPI["CodexReviewStore<br/>direct observation"]
    MCP --> ToolProtocol["ReviewToolProtocol"]
    CLI --> ToolProtocol
    ToolProtocol --> StoreProtocol["ReviewStoreProtocol"]
    StoreProtocol --> Store["CodexReviewStore"]
    Store --> Workflows["ReviewApplication workflows"]
    Store --> Observation["Observation / ObservationBridge"]
    Observation --> NativeUI["Native AppKit / SwiftUI rendering"]
```

### Application 内部

この図の矢印は `ReviewApplication` 内部の状態更新と workflow 呼び出しの流れです。

```mermaid
flowchart TB
    Store["CodexReviewStore<br/>source of truth"]
    State["Observable state<br/>auth / settings / workspace / job"]
    Workflows["Workflows<br/>ReviewWorkflow / AuthWorkflow / SettingsWorkflow / ServerWorkflow"]
    Dependencies["ReviewPorts<br/>ReviewEngine port"]

    Store --> State
    Store --> Workflows
    Workflows --> Dependencies
```

### 外部連携

この図の点線は `ReviewPorts` に対する live 実装の提供関係です。`ReviewPlatform` は `ReviewPorts` を実装するのではなく、live adapter / runtime が使う platform primitive を提供します。

```mermaid
flowchart LR
    Dependencies["ReviewPorts<br/>ReviewEngine"]
    AppServerAdapter["ReviewAppServerAdapter<br/>ReviewEngine + app-server clients"]
    Runtime["ReviewServiceRuntime<br/>live wiring"]
    PlatformServices["ReviewPlatform<br/>file / process / clock / runtime registry"]
    AppServer["codex app-server"]
    Files["~/.codex_review"]

    AppServerAdapter -.->|implements ReviewEngine| Dependencies
    Runtime --> AppServerAdapter
    Runtime --> PlatformServices
    AppServerAdapter --> PlatformServices
    AppServerAdapter --> AppServer
    PlatformServices --> Files
```

## Swift Package ターゲット依存

現在の target 一覧です。この表を SwiftPM target 構成の基準として扱います。

### 依存方向の注意

`ReviewApplication` は live dependency target を import しません。monitor app / server の live wiring は `ReviewServiceRuntime` に置き、`ReviewApplication` は store、state、workflow、preview/testing harness の境界だけを持ちます。

`ReviewServiceRuntime` は composition root を補助する target です。`ReviewApplication`, `ReviewMCPAdapter`, `ReviewAppServerAdapter`, `ReviewPlatform` を組み立て、live の `CodexReviewStore` を作ります。

### Target 一覧

| Target | 種別 | 役割 | 依存先 |
| --- | --- | --- | --- |
| `ReviewDomain` | library | request / response / settings / account / cancellation などの pure value | なし |
| `ReviewPorts` | library | `ReviewStoreProtocol`, `ReviewToolProtocol`, `ReviewEngine` と process event / outcome | `ReviewDomain` |
| `ReviewApplication` | library | `CodexReviewStore`、observable state、workflow、preview/testing harness | `ReviewPorts`, `ReviewDomain`, `ObservationBridge` |
| `ReviewServiceRuntime` | library | monitor app / server の live store factory、server lifecycle、auth orchestration、settings backend wiring | `ReviewApplication`, `ReviewPorts`, `ReviewAppServerAdapter`, `ReviewDomain`, `ReviewPlatform`, `ReviewMCPAdapter`, `ObservationBridge` |
| `ReviewUI` | library | AppKit / SwiftUI の direct native rendering | `ReviewApplication`, `ReviewDomain`, `ObservationBridge` |
| `ReviewMCPAdapter` | library | MCP / HTTP/SSE / STDIO の入力を `ReviewToolProtocol` に変換する adapter | `ReviewDomain`, `ReviewPorts`, `ReviewPlatform`, `MCP`, `NIO`, `Logging` |
| `ReviewAppServerAdapter` | library | `codex app-server` と話す live dependency 実装 | `ReviewPorts`, `ReviewDomain`, `ReviewPlatform`, `MCP`, `TOMLDecoder` |
| `ReviewPlatform` | library | file/process/clock/runtime registry/local config の live dependency 実装 | `ReviewDomain` |
| `ReviewCLI` | library | CLI / executable の composition root | `ReviewApplication`, `ReviewMCPAdapter`, `ReviewServiceRuntime`, `ReviewAppServerAdapter`, `ReviewPlatform`, `Logging` |
| `CodexReviewMCPCommand` | executable | `codex-review-mcp` entry point | `ReviewCLI` |
| `CodexReviewMCPServerCommand` | executable | server executable entry point | `ReviewCLI` |
| `ReviewTestSupport` | test support library | fake dependencies、deterministic clock、test builders | `ReviewApplication`, `ReviewAppServerAdapter`, `ReviewDomain`, `ReviewPlatform`, `ReviewMCPAdapter`, `ReviewServiceRuntime` |

`CodexReviewMonitor` は SwiftPM target ではなく Xcode app target です。現在は `ReviewUI`, `ReviewApplication`, `ReviewServiceRuntime` を直接参照します。

次の図では SwiftPM の主要 edge を描きます。`ReviewDomain` は pure values として多くの target から参照されるため、図からは省略します。executable から composition root への依存も下の表に分けます。

```mermaid
flowchart TB
    subgraph Inputs["Input targets"]
        direction LR
        ReviewUI["ReviewUI<br/>UI rendering"]
        ReviewMCPAdapter["ReviewMCPAdapter<br/>MCP / HTTP/SSE / STDIO"]
    end

    subgraph AppCore["Application core"]
        direction TB
        ReviewApplication["ReviewApplication<br/>store / state / workflows"]
        ReviewPorts["ReviewPorts<br/>Store / Tool / Engine protocols"]
        ReviewApplication --> ReviewPorts
    end

    subgraph Live["Live dependency targets"]
        direction LR
        ReviewAppServerAdapter["ReviewAppServerAdapter<br/>codex app-server"]
        ReviewPlatform["ReviewPlatform<br/>platform / file / process"]
        ReviewServiceRuntime["ReviewServiceRuntime<br/>monitor / server live wiring"]
    end

    subgraph Roots["Composition roots"]
        direction LR
        ReviewCLI["ReviewCLI"]
        CodexReviewMonitor["CodexReviewMonitor"]
    end

    ReviewUI --> ReviewApplication

    ReviewAppServerAdapter --> ReviewPorts
    ReviewServiceRuntime --> ReviewApplication
    ReviewServiceRuntime --> ReviewMCPAdapter
    ReviewServiceRuntime --> ReviewAppServerAdapter
    ReviewServiceRuntime --> ReviewPlatform

    ReviewCLI --> ReviewMCPAdapter
    ReviewCLI --> ReviewApplication
    ReviewCLI --> ReviewServiceRuntime
    ReviewCLI --> ReviewAppServerAdapter
    ReviewCLI --> ReviewPlatform

    CodexReviewMonitor --> ReviewUI
    CodexReviewMonitor --> ReviewApplication
    CodexReviewMonitor --> ReviewServiceRuntime
```

この図では、`ReviewApplication -> ReviewMCPAdapter / ReviewAppServerAdapter / ReviewPlatform` の edge はありません。live target の合流点は `ReviewServiceRuntime` と composition root だけです。

補足:

- `ReviewDomain` は shared value target です。`ReviewApplication`, `ReviewPorts`, adapter, live dependency target から参照されますが、主要な依存を読みやすくするため図では省略しています。
- `CodexReviewMCPCommand` と `CodexReviewMCPServerCommand` はどちらも `ReviewCLI` だけに依存します。
- `ReviewTestSupport` は production target から参照しません。

### Composition root wiring

| Composition root | 組み立てる target |
| --- | --- |
| `ReviewCLI` | `ReviewApplication`, `ReviewMCPAdapter`, `ReviewServiceRuntime`, `ReviewAppServerAdapter`, `ReviewPlatform` |
| `CodexReviewMonitor` | `ReviewApplication`, `ReviewUI`, `ReviewServiceRuntime` |
| `CodexReviewMCPCommand` | `ReviewCLI` |
| `CodexReviewMCPServerCommand` | `ReviewCLI` |

## 今後の見直し候補

| 現状 | 目標 |
| --- | --- |
| `ReviewServiceRuntime` の source file は責務別に分割済みだが、`ReviewMonitorServerRuntime` / `ReviewMonitorAuthOrchestrator` 自体はまだ大きい | 必要なら class 内の server lifecycle、auth orchestration、settings backend、runtime recycle をさらに小さな runtime component に分ける |
| `ReviewMonitorServerRuntime` に server/settings/auth/recycle が集中する | runtime target 内で `ServerWorkflow`, `SettingsWorkflow`, `AuthWorkflow`, `ReviewWorkflow` 相当へ分ける |
| `ReviewCLI` が CLI helper の都合で live targets も直接 import している | composition root として許容しつつ、不要な direct import が増えないように維持する |

## review_start の実行フロー

STDIO クライアントの場合も HTTP/SSE クライアントの場合も、MCP adapter は request を store intent に変換します。review 実行の live details は `ReviewPorts` の実装側に閉じ込めます。

この sequence の矢印は `review_start` の呼び出しと結果返却の流れです。target import 依存ではありません。

```mermaid
sequenceDiagram
    autonumber
    participant Client as MCP client
    participant Adapter as ReviewMCPAdapter
    participant Tool as ReviewToolProtocol
    participant StoreAPI as ReviewStoreProtocol
    participant Store as CodexReviewStore
    participant Workflow as ReviewWorkflow
    participant Deps as ReviewPorts
    participant Live as ReviewAppServerAdapter
    participant Codex as codex app-server

    alt HTTP/SSE client
        Client->>Adapter: initialize / call review_start
    else STDIO client
        Client->>Adapter: JSON-RPC over stdio
    end
    Adapter->>Tool: invoke review_start intent
    Tool->>StoreAPI: startReview(sessionID, request)
    StoreAPI->>Store: forward to source-of-truth store
    Store->>Workflow: startReview(sessionID, request)
    Workflow->>Store: enqueueReview(...)
    Workflow->>Deps: run review through ReviewEngine port
    Deps->>Live: dispatch to live implementation
    Live->>Codex: config/read
    Live->>Codex: thread/start
    Live->>Codex: review/start
    Codex-->>Live: notifications / agent output / completion
    Live-->>Workflow: events / final outcome
    Workflow-->>Store: mutate job state
    Store-->>StoreAPI: ReviewReadResult
    StoreAPI-->>Tool: ReviewReadResult
    Tool-->>Adapter: structured tool result
    Adapter-->>Client: structured MCP result
```

補足:

- `review_start` は最終結果まで待つ primary flow です。
- `review_read` / `review_list` は `CodexReviewStore` 上の session-scoped job state を読むだけの軽い経路です。
- `review_cancel` は `ReviewWorkflow` から `ReviewPorts` へ cancellation を渡し、live 実装が app-server の interrupt / cleanup details を扱います。

## State と Observation の流れ

この図の矢印は状態更新と observation delivery の流れです。`ReviewPorts` 以外は target import 依存を表していません。

```mermaid
flowchart LR
    Intent["User action / MCP tool call"] --> StoreAPI["ReviewStoreProtocol / CodexReviewStore intents"]
    StoreAPI --> Workflows["ReviewApplication workflows"]
    Workflows --> Dependencies["ReviewPorts"]
    Dependencies -.->|ReviewEngine implementation| Outcome["events / outcomes"]
    Outcome --> Mutation["Mutate @Observable state<br/>serverState, auth, workspaces, jobs"]
    Mutation --> Observation["Observation / ObservationBridge"]
    Observation --> NativeUI["AppKit / SwiftUI native rendering"]

    UIState["ReviewMonitorUIState<br/>selected job, sidebar selection,<br/>content presentation"] --> NativeUI
    Mutation --> StoreTree["CodexReviewStore<br/>- auth<br/>- settings<br/>- workspaces"]
    StoreTree --> WorkspaceTree["CodexReviewWorkspace<br/>- jobs"]
    WorkspaceTree --> JobTree["CodexReviewJob<br/>- status<br/>- summary<br/>- log projections"]
```

整理後の state ownership:

- `CodexReviewStore` が UI と MCP server の両方から使われる root state です。
- `CodexReviewAuthModel` は認証・アカウント選択の source of truth です。
- `CodexReviewWorkspace` は cwd ごとの job grouping と展開状態を持ちます。
- `CodexReviewJob` は review status、summary、thread/turn ID、log entry と表示用 projection を持ちます。
- `ReviewMonitorUIState` は選択中 job や sidebar selection など、画面固有の一時 UI state を持ちます。
- AppKit controller は `ObservationBridge` の `ObservationScope` で store/job を直接 observe し、native view を更新します。

## 主な責務境界

この図の矢印は boundary をまたぐ intent / workflow / external effect の流れです。target import 依存は Swift Package ターゲット依存の図だけで扱います。

```mermaid
flowchart TB
    subgraph InputBoundary["Input boundary"]
        UIIntent["UI intent"]
        MCPIntent["MCP tool call"]
        CLIIntent["CLI command"]
        StoreBoundary["ReviewStoreProtocol"]
        ToolBoundary["ReviewToolProtocol"]
    end

    subgraph AppBoundary["Application boundary"]
        StoreState["CodexReviewStore state"]
        WorkflowRules["Workflow rules"]
        DependencyBundle["ReviewPorts<br/>Store / Tool / Engine protocols"]
    end

    subgraph AppServerBoundary["ReviewAppServerAdapter boundary"]
        AppServerAdapters["App-server dependency implementations"]
        SharedAppServer["codex app-server"]
    end

    subgraph PlatformBoundary["ReviewPlatform boundary"]
        PlatformAdapters["Platform dependency implementations"]
        RuntimeFiles["discovery / runtime-state / account files"]
    end

    UIIntent --> StoreBoundary
    MCPIntent --> ToolBoundary
    CLIIntent --> ToolBoundary
    ToolBoundary --> StoreBoundary
    StoreBoundary --> StoreState
    StoreState --> WorkflowRules
    WorkflowRules --> DependencyBundle
    AppServerAdapters -.->|supplies ReviewEngine| DependencyBundle
    AppServerAdapters --> SharedAppServer
    AppServerAdapters --> PlatformAdapters
    PlatformAdapters --> RuntimeFiles
```

責務の読み方:

- Input boundary は intent 変換だけを担当します。
- Application boundary は state と workflow rules を持ち、外部副作用は `ReviewPorts` に閉じます。
- ReviewAppServerAdapter boundary は `codex app-server` protocol details を担当します。UI layer からは直接見えません。
- ReviewPlatform boundary は file/process/clock/runtime registry を担当します。`ReviewPorts` を直接実装せず、adapter / runtime に platform primitive を提供します。

## 見直し時の起点

現状把握から見える、次に議論しやすい論点です。

1. `ReviewMonitorServerRuntime` / `ReviewMonitorAuthOrchestrator` に残る server lifecycle、settings、auth seed、runtime recycle を、必要に応じて小さな runtime component に分けます。
2. `ReviewApplication -> ReviewMCPAdapter / ReviewAppServerAdapter / ReviewPlatform` の target edge は存在しません。この状態を維持します。
3. UI は直接 observation で描画しており、余分な ViewModel 層はありません。この点は維持します。
