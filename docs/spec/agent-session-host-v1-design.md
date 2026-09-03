# Agent Session Host v1 — 守护进程持有 Agent Mode 会话（设计草案）

Status: **accepted, implementation in progress**（2026-09-02；ADR-0011 Accepted；六项裁决见 §11；实施进度见 §12；**P8 + 凭据 addendum Accepted 2026-09-03**）。配套决策记录：[`adr-0011-agent-session-host.md`](../architecture/adr-0011-agent-session-host.md)。

> 证据标记沿用 `docs/investigations/architecture-full-flow-2026-09-01.md` 的约定：**【码】**= 已读源码验证；**【文】**= 仓库文档主张；**【参】**= 来自 Prime Agent 源码/文档（`PrimeIntellect-ai/prime-agent` `0ba0423c`，2026-09-02）；**【推】**= 推断或设计选择。

---

## 0. 一句话

把 Agent Mode 会话的**执行归属**从 `Agentry.app` GUI 进程搬到一个按用户驻留的 **Agent Session Host**（下称 host）进程；GUI、`agentry-mcp` CLI、未来的 Agents View 都退化为可附着/可脱离的**客户端**。只搬 Agent 域，不搬 core；workspace authority 留在原地。

**长期定位（Rust 为核心）**：本设计的两份长期合同是 **wire 协议**（`agentry-proto` 导出）与**落盘格式**（同一 schema 的 append-only 事件日志）。二者从第一天起按"Rust 二进制可原样接手"来定义。host 的 **Swift 外壳是过渡实现**，其存在理由只是 Codex/ACP 的协议语义、transcript、run 生命周期归约与持久化今天仍在 Swift；host 进程同时被指定为 charter Phase 6（Agent 语义权威迁 Rust）的**落地场**——搬完那天 host 二进制换成 Rust，客户端与磁盘文件不变。

---

## 1. 问题：今天为什么做不到"关掉 GUI 让它继续跑"

| 事实 | 证据 |
|---|---|
| GUI 是唯一活体宿主：`AgentModeViewModel.sessions: [UUID: AgentTabSession]`（`@MainActor`）持有 transcript、run state 与 provider controller | 【码】`AgentModeViewModel.swift:472`、`AgentTabSession.swift:12-13` |
| OS 子进程由 Rust 拥有（`AgentClaudeScope` / `agent_provider`），但 handle 挂在 `AgentTabSession.{claudeController,codexController,acpController}` 上 | 【码】`ClaudeRustBackedNativeSessionAdapter.swift:129,359`、`AgentProviderRuntimeTransport.swift:1-7` |
| 退出时明确杀掉所有 agent 子进程：`applicationShouldTerminate` → `shutdownAllAgentSessions()` → 每会话 `prepareSessionForWindowClose` → cancel run + dispose provider | 【码】`AppDelegate.swift:239-268`、`WindowStateManager.swift:1032-1050`、`AgentModeViewModel.swift:3345-3451` |
| MCP `agent_run` 对 GUI 已激活的 run **拒绝接管**："The requested agent run is active but is not controlled by this MCP handle." | 【码】`AgentRunMCPToolService.swift:1106-1110` |
| 没有任何"第二个客户端附着到运行中 agent"的产品概念；`detach=true` 只表示"不等待" | 【码】`MCPAgentControlToolProvider.swift:95,136` |
| 会话持久化是 1s 防抖 + 整文件原子重写 `AgentSession-<uuid>.json`，不是 append-only | 【码】`AgentSessionDataService.swift:107-109,959-987` |
| 交互式 Claude 原生运行时被文档钉为 GUI-scope："constructed only inside the `@MainActor` `AgentModeViewModel`… `Sources/RepoPromptMCP` constructs neither interactive symbol" | 【文】`rust-agent-claude-v1.md:35-37` |

后果：GUI 崩溃/退出/更新 = 所有 run 一起死；同一个 run 不能同时被两个窗口或 CLI 观察；长时任务与 GUI 生命周期绑死。

Charter 已经预留了这条路：§14.2 把"UI 重启时 Agent/session 必须继续存活"与"多前端共享 authority"列为**允许**引入本地 RPC/daemon 的触发条件，同时约束"优先只隔离问题域，而不是把整个 core 预先改为 daemon；外部进程协议必须使用项目自有 schema，不复用 UniFFI 内部格式"。§18 第 9 条（"何种 crash/session-survival 指标会正式触发 Agent runtime XPC/daemon 化"）至今未裁决。本设计与 ADR-0011 就是对这一条的回答。【文】`agentry-rewrite-charter.md:700-710,859`

---

## 2. 目标与非目标

### 2.1 目标

1. GUI 退出、崩溃、Sparkle 更新重启后，运行中的 Agent Mode 会话**不中断**；重新打开 GUI 可附着回去并看到完整 transcript 与实时事件。
2. 同一会话可被多个客户端同时附着（多窗口、`agentry-mcp` CLI、未来 Agents View），任一客户端脱离不影响执行。
3. 会话所有权、事件游标、命令幂等、恢复语义在**一处**定义，且与现有 Domain 权威（`DomainAgentRun*`、M5 会话元数据围栏）连续，不另造第二套。
4. 只隔离 Agent 域；workspace authority、MCP catalog、搜索等继续按现状（GUI lease 或 headless direct）运行。
5. 协议与落盘格式是长期合同：由 `agentry-proto` 单一作者点定义，语言中立，Rust host 可原样接手；wire 上不携带本地文件系统语义（不透明 ID、字符串时间戳、显式 artifact 句柄），为远程传输保留可能。
6. 协议对进程拓扑透明：客户端只按 `sessionID` 寻址，host 内部是单进程直跑还是路由到 per-session worker 在 wire 上不可见，拓扑升级不 bump 协议。
7. 表面积最小：v1 命令面九条（§5.4），调度/心跳/目标等不进 host 协议，留在 `agent_run` 既有语义与客户端侧。

### 2.2 非目标

- 不把整个 `CoreRuntime` 改为 daemon（charter §14.2 明令）。
- 不引入 launchd / LaunchAgent / XPC service（charter §2.2 第一阶段非目标；v1 由客户端按需拉起，见 §4.4）。
- 不做安全沙箱：host、客户端、provider 子进程仍是同一 OS 用户；这是进程协调边界，不是信任边界。【参】Prime `daemon.md` 同样声明。
- 不做远程/托管执行；协议仅本机 Unix socket，不设计认证/网络兼容策略。
- 不改变对外 MCP wire、`agent_run`/`agent_manage` 现有操作的语义（只新增 `attach`）。
- 不采纳 Prime Agent 的 RLM 单工具范式或 Continual Harness 自改写。

---

## 3. 参照：Prime Agent 的同类设计要点【参】

| Prime Agent | 对应 Agentry 已有物 | 差距 |
|---|---|---|
| supervisor 拥有公共 socket、attach、路由、worker 健康；不执行 provider/tool | `ServerController` + `MCPConnectionManager`（进程级 bootstrap listener）| Agentry 的 listener 在 GUI 进程内 |
| 每 root session 一个 worker 进程，崩溃只影响一棵树；250ms/1s/5s 三次恢复 | provider 子进程已独立，但会话状态与 transcript 在 GUI 进程 | 没有 worker 层 |
| `DaemonEventCursor { generation, sequence }`，generation 变则序号不可比；attach 返回 replay `complete\|partial\|unavailable` + 快照；Prime 把快照当恢复基线、replay 当优化，但其磁盘真相是 append-only JSONL | Rust `SubscriptionHub` 的 `streamID + deliveryCursor` + 原子 bootstrap 快照 + gap → `resnapshotRequired` | Agentry 的 hub 是**进程内**多订阅，未跨进程；本文 §7.2 取 Prime 的磁盘模型（事件日志 canonical），快照仅为派生 |
| 命令 `clientId + commandId` 幂等，dispatch 前 append-only journal；重连后无 durable 结果 → 报 uncertain，不盲重放 | `OperationID` 调用方预生成；同 ID 同 fingerprint 幂等，不同 → `operationConflict`；first-terminal-wins tombstone | 语义等价，Agentry 缺跨进程 journal |
| `DaemonPeerTransportTicket`：socket `{dev,ino}` 身份 + 一次性 token + 过期 | run-scoped carrier：私有 endpoint + 一次性 launch token + principal/provider/runID 校验 | 等价，可直接复用 |
| `session-lease.ts`：per-session 文件 lease，`session_already_active` | `DomainWorkspaceAuthorityLease`（flock）+ M5 会话元数据 `active` 状态所有权围栏 | 等价 |
| 背压 attachment-local：慢客户端停止收增量，drain 后从 cursor 追或重拿快照；supervisor 无无界 per-client 队列 | charter §6.1 第 6 条：每条队列同时有 count 与 byte 上限 | 一致 |
| 两阶段协调更新：worker 并行 checkpoint → supervisor 校验并原子落 manifest → 全部成功才 commit 并停 worker | 无 | 需新增（Sparkle 更新会替换 host 二进制）|
| `AgentConnection` 客户端边界；`InteractiveMode` 不得依赖 runtime/session/daemon 类型，有专门 boundary test | 无对应 seam；`AgentModeViewModel` 直接持 controller | 需新增 seam + guardrail |

结论：Agentry 缺的不是原语，而是**把这些原语用在跨进程边界上**的那一层。

---

## 4. 目标拓扑

```
┌───────────────── Agentry.app (GUI, 可退出) ─────────────────┐
│ AgentModeViewModel / AgentTabSession (presentation only)   │
│        │ AgentSessionConnection (client seam, §6)          │
│        ▼                                                   │
│ HostAgentSessionConnection ──── Unix socket (§5) ──────────┼──┐
│                                                            │  │
│ workspace authority / MCP bootstrap listener（P8：GUI 缺席可 fence-claim）│◄─┼──── provider 子进程 --backend auto
└────────────────────────────────────────────────────────────┘  │     (agentry-mcp proxy, 有 reconnect)
                                                                │
┌──────────── agentry-mcp agent-host（按用户驻留）────────────┐  │
│ host lease (flock)  ·  host identity  ·  client attachments │◄─┘
│ AgentSessionHostRuntime                                     │
│   ├─ session A: Domain run lifecycle + transcript authority │
│   │     └─ Rust AgentClaudeScope / agent_provider → 子进程   │
│   ├─ session B …                                            │
│   └─ SubscriptionHub → per-client bounded fanout            │
│ 持久化：AgentSession-<uuid>.json（snapshot）+ .events（append）│
└─────────────────────────────────────────────────────────────┘
        ▲
        │ 同一协议
┌───────┴────────┐
│ agentry-mcp CLI│  agent_run {attach|steer|wait|cancel}
└────────────────┘
```

### 4.1 host 是 `agentry-mcp` 的一个模式，不是新二进制【推】

理由：
- `agentry-mcp` 已随 app bundle 签名分发（`Contents/MacOS/agentry-mcp`），并被 `DirectHeadlessMCPService` 证明能在无 AppKit 下组装 `MCPDomainRuntime`、私有子进程 endpoint、launch-token 兑换。【码】`DirectHeadlessMCPService.swift:61-111,263-270,389-412`
- `headless_runtime_guardrails.sh` 已经守着"无 MainActor/UI 依赖"，host 代码天然落在同一守卫下。
- 二进制无关：今天是 Swift target `RepoPromptMCP`，charter 终态是 Rust `bins/agentry-mcp`；host 模式随之迁移，协议不变。

入口：`agentry-mcp agent-host [--idle-exit-seconds N]`。interactive/exec 等 app-only 能力与之无关。

#### 4.1.1 为什么 v1 外壳只能是 Swift，以及它如何变成 Rust【码/推】

Rust 今天拥有的 Agent 权威：Claude 交互式的进程/NDJSON/turn/control（`agent_claude::AgentClaudeScope`）、Claude headless 的 stream translator、Codex app-server 与 ACP 的进程与 JSON-RPC 相关性（`agent_provider` + `provider_json_rpc`）。仍在 Swift 的：Codex/ACP 协议**语义**（typed notification 解释、模型/权限选项协商）、transcript 归约与发布、`DomainAgentRun*` 生命周期归约器、MCP 权限策略、会话持久化。一个纯 Rust host 今天跑不完任何一条非 Claude 会话，所以 v1 外壳是 Swift 不是选择而是约束。

让它不成为"建两遍"的办法：

| 层 | v1（Swift 外壳） | 终态（Rust 二进制） | 是否重写 |
|---|---|---|---|
| wire 协议 | `agent_host_v1.proto`，Swift 消费生成物 | 同一 `.proto`，Rust 原生 | 否 |
| 落盘事件日志 | 同一 proto 事件记录，Swift 写 | Rust 写 | 否 |
| lease / socket 路径 / 身份握手规则 | Swift 实现 | Rust 实现 | 规则不变，实现重写（数百行） |
| provider 进程与协议传输 | 已在 Rust | 不动 | 否 |
| run 生命周期归约器 `DomainAgentRun*` | Swift（值状态，无 UI） | Rust（Phase 6） | 一次性移植，本来就在 charter 计划内 |
| transcript 归约、权限策略、Codex/ACP 语义 | Swift | Rust（Phase 6） | 同上 |
| 客户端（GUI/CLI） | `HostAgentSessionConnection` | 不变 | 否 |

真正被丢弃的只有第三行的 Swift 实现——socket server、fanout、codec 胶水。其余要么本来就是 Rust，要么是 charter Phase 6 无论如何都要搬的东西，host 只是给它们一个没有 UI 的落地进程。**Phase 6 的每一个语义 cutover 都在 host 进程内进行**（而不是在 GUI 里），因为 host 没有 `@MainActor`，正是 `headless_runtime_guardrails.sh` 守着的那种边界。

### 4.2 进程内隔离 vs 每会话 worker【推，已裁决：v1 单 host，见 §11 第 1 条】

Prime 选每 root 一个 worker 进程换崩溃隔离。Agentry v1 **不**这样做：
- provider 本体（claude/codex CLI）已经是独立 OS 进程，最重的崩溃面已在进程外。
- host 内没有 UI 代码，崩溃面远小于今天的 GUI。
- 代价：Rust panic guard 是 runtime 级 poison（`internalPanic` → `runtimePoisoned`），一次 panic 会拖垮 host 内所有会话。这与今天 GUI 崩溃的爆炸半径相同，不更差。

裁决点：以 P3 beta soak 的 host 崩溃率作为 charter §14.2 "crash budget" 触发条件——若 host 每周非零崩溃且影响 >1 个并发会话，进入 P5 每会话 worker。SLO 在 P3 开始前登记（ADR-0008）。

**拓扑透明不变量**（使 P5 成为非破坏性升级的前提）：
- 客户端寻址单位是 `sessionID`；wire 上没有 worker ID、worker socket、worker 进程身份。
- `generation` 对客户端是不透明字节串；host 内部可以把 `hostInstanceNonce ‖ workerInstance ‖ attemptID` 编码进去，客户端只做"相等则可比、不等则不可比"。
- attach/snapshot/事件推送都由 host 公共 socket 交付；即便未来 worker 直连（Prime 的 `get_direct_worker_transport`）也只能作为**可选能力**协商，不得成为基础寻址路径。
- 因此 v1 单进程是 P5 拓扑的退化情形：supervisor 与 worker 是同一进程，路由表只有一项。
- host 内部从 v1 起按 `SessionRouter { sessionID → SessionExecutor }` 分层：router 拥有 socket、lease、fanout、事件日志句柄；executor 拥有 provider 会话与 run 归约。P5 只是给 `SessionExecutor` 换一个跨进程实现，router 与其上的一切不动。

### 4.3 workspace authority 不动【推】

provider 子进程经 `agentry-mcp --backend auto` 访问 workspace/apply_edits 等工具。`--backend auto` 以既有 `DomainWorkspaceAuthorityLease` flock 为 GUI 在场权威：live GUI-shaped holder（`mode == "app"`）→ 固定 `.app` proxy，不偷 GUI lease；lease unused → 再做既有 bootstrap socket probe，不可达则 `.headless`。`.app` proxy 自带 reconnect（60s 内 0.5s 重试，之后指数退避至 30s）与 initialize/outstanding 请求重放。【码】`MCPBackendSelection.swift`、`main.swift`

**P8（2026-09-03 Accepted）：** GUI 缺席（lease unused / flock free / 无 live GUI fingerprint）时，`--backend auto`→headless 按 CLI headless 规则 fence-claim 同一 `workspace-authority-v1.lock`（单写者，冲突 fail closed）。生产 Rust `agent-host` **不**自己 claim 该 flock，避免与执行工具的 MCP 子进程双写。GUI 重开走既有 proxy reconnect/replay。inventory/search 仍留在 GUI FFI（ADR-0008）；charter §14.2 只多隔离这一条 workspace lease 给 agent 工具 mutation。

长期看 inventory/search 这条边界仍对：ADR-0008 实测过 inventory 域跨边界往返在 10 万文件规模下慢 50–80 倍并因此被否决 cutover。workspace/search/inventory 这类延迟敏感、读多写少的域应当留在 GUI 进程内的 FFI 边界上；只有长时执行域（Agent）加上 GUI 缺席时的 workspace **lease** 值得付跨进程代价。"整个 core 做成 daemon、GUI 纯客户端"不是更优终态。

### 4.4 host 生命周期【推】

- **拉起**：任一客户端（GUI 启动 Agent Mode、CLI `agent_run start`）发现 host socket 不可连时，spawn `agentry-mcp agent-host` 为独立进程组（`setsid`），不继承客户端 stdio，随后连接。竞争拉起由 host lease 收敛：后到者拿不到 lease 即退出，客户端重连。
- **驻留**：有任一会话处于 `active` 或有任一客户端附着时保持运行。
- **空闲退出**：零会话活跃且零附着持续 `--idle-exit-seconds`（默认 300）后自行退出，同时释放 `ProcessInfo.beginActivity`，满足 charter §11.5"空闲零唤醒"。
- **GUI 退出**：`applicationShouldTerminate` 序列改为：detach 所有 host 连接 → 不再 `shutdownAllAgentSessions`。用户显式"Stop all agents"仍可下发 `interrupt` 命令。**这是对 charter §11.6 序列的修订**，ADR-0011 记录。
- **Sparkle 更新**：新 GUI 与旧 host 的 `buildFingerprint` 不匹配 → attach fail closed（ADR-0006 精神）。新 GUI 先发 `prepare_update`：host 对每个活跃会话做非破坏 checkpoint（写 snapshot + events flush），全部成功后 host 以 `update` 原因关闭并退出；新 GUI 再拉起新 host，新 host 以 M5 fenced claim 接管处于 `interrupted` 状态的会话（provider 子进程已随旧 host 结束，恢复 = 从 provider 的 resume ID 续接，与今天"resume session"路径相同）。任一 checkpoint 失败则不更新 host，旧 host 继续运行并向用户报告。

---

## 5. 传输与协议

### 5.1 位置与权限

- socket：`/tmp/agentry-mcp-<uid>/agentry-agent-host-{D-}<v>.sock`，与现有 bootstrap socket 同目录、同 flavor 命名规则、目录 0700。【码】`MCPFilesystemIdentity.swift:45-51,130-136`
- host lease：`<Application Support>/Agentry/.agentry-domain-runtime/locks/agent-host-v1.lock`，`flock(LOCK_EX|LOCK_NB)`，owner 元数据仅诊断；持有者被 `SIGKILL` 时内核释放（已有跨进程测试范式）。【码】`DomainWorkspaceAuthorityLease.swift:477-498`、`DomainWorkspaceAuthorityLeaseTests.swift:476-515`

### 5.2 帧与 schema

- 帧：`4 字节 payload 长度 (BE) + Protobuf payload`，上限 1 MiB（与 FFI envelope 上限一致）；超限 payload 走 chunk 化 snapshot（§5.5）。
- schema：`rust/crates/proto/agent_host/agent_host_v1.proto`，由 `agentry-proto` 单一作者点导出，Swift 侧消费生成物（ADR-0009）。**不复用 UniFFI 内部格式，不复用 MCP JSON-RPC**（charter §14.2）。
- 分帧不用换行；若将来需要文本调试模式，遵循 Prime `rpc/jsonl.ts` 的规则：只按 `\n` 切、剥 `\r`、不用把 U+2028/2029 当换行的 reader。【参】

**wire 字段规则（长期合同，P2 冻结）：**

| 规则 | 理由 |
|---|---|
| 会话、附着、交互、artifact 一律用不透明 ID（UUID 字节或字符串），不用磁盘路径 | 为远程/托管传输保留可能；Prime `agent-connection.md` "Local-Only Data" 的教训【参】 |
| `sessionSpec` 引用 workspace 用 `workspaceID`（canonical 存储中的身份），不用绝对路径；provider 命令路径、环境、凭据不进 wire——由 host 侧 launch resolver 解析（现有 `ClaudeCompatibleLaunchEnvironmentResolver` 模式） | 路径只在 host 本机有意义；凭据零化规则要求字节不跨传输 |
| 时间戳用 RFC 3339 字符串或 `google.protobuf.Timestamp`，不用本机 `Date` 二进制 | 语言中立 |
| 大对象（transcript 快照、附件）只以 `artifactID + byteLength + digest` 引用，通过 `snapshot_chunk` 流式传输 | 与 1 MiB 帧上限一致；未来可换成显式 download 句柄 |
| 所有 enum 保留 `_UNSPECIFIED = 0`，所有 message 可加字段；不兼容改动 bump `protocolVersion` | proto 演进纪律，与 ADR-0009 一致 |
| 不引用 Swift/Rust 内部类型名；事件词汇以 provider-neutral DTO 为准 | Rust 接手时零翻译 |

### 5.3 握手与身份

```
Client → Hello { protocolVersion, clientKind(gui|cli|view), clientID(stable), buildFingerprint, pid }
Host   → Welcome { protocolVersion, hostInstanceNonce, buildFingerprint, capabilities[], leaseEpoch }
```

- host 用 `LOCAL_PEERPID` 取对端 PID，用现有 `proc_pidpath + st_dev|st_ino` 摘要校验对端可执行文件与自身同 bundle。【码】`BootstrapSocketServer.swift:786-797`、`MCPConnectionManager.swift:13091-13102`
- **双向** `buildFingerprint` 不匹配 → fail closed（补上今天 CLI 不校验 GUI 二进制的缺口）。
- `hostInstanceNonce` 是事件 generation 的一部分：host 重启即换 nonce，旧 cursor 不可比。
- 能力协商：`capabilities[]` 字符串集合；兼容性新增走 capability，不兼容改动升 `protocolVersion`。【参】Prime protocol v4 规则

### 5.4 命令面（v1 最小集）

| 命令 | 语义 | 幂等键 |
|---|---|---|
| `list_sessions` | host 内活跃会话 + 元数据（不含 transcript） | 只读 |
| `attach { sessionID, resumeCursor? }` | 返回 `AttachResult { snapshot(chunked), cursor, replay: complete\|partial\|unavailable }`，随后开始推送事件 | 只读 |
| `detach { sessionID }` | 停止推送；不影响执行 | 只读 |
| `start { sessionSpec, operationID }` | 新建会话并启动 run | `operationID` |
| `steer { sessionID, message, operationID }` | 续接现有会话 | `operationID` |
| `interrupt { sessionID, reason, operationID }` | 中断当前 turn | `operationID` |
| `respond_interaction { sessionID, interactionID, answer, operationID }` | 回答 permission / ask_user | `operationID` |
| `stop_session { sessionID, operationID }` | 结束会话并释放 provider | `operationID` |
| `prepare_update` / `shutdown { force? }` | §4.4 | 只读/幂等 |

幂等规则沿用 FFI 控制面：调用方预生成 `operationID`（canonical UUID）；同 ID 同 fingerprint = 返回已记录结果；不同 fingerprint = `operationConflict`；host 收到但无 durable 结果 = 返回 `uncertain`，**不**盲重放。【码】`rust/ffi-contract/abi-v1.json` 语义；【参】Prime `clientId + commandId`

命令的 durable 记录就是事件日志本身（§7.2）：每条 mutating 命令在 dispatch 前追加一条 `CommandAccepted{operationID, fingerprint}` 记录，终态追加 `CommandSettled{operationID, result}`。幂等查询即扫这两类记录；不另设 journal 文件。

这九条是 v1 的**全部**命令面。调度、心跳、目标、side-question、模型目录等不进 host 协议：它们要么属于客户端（模型目录由 GUI 自己解析），要么属于 `agent_run` 已有的 MCP 语义层。新增命令需要 capability 协商，删除命令需要 `protocolVersion` bump。

### 5.5 事件面

- 每事件带 `{ generation: hostInstanceNonce ‖ sessionAttemptID, deliveryCursor }`；`deliveryCursor` 在单次 attach 内连续递增。gap 判定只用 `deliveryCursor`，不可用 authority publication sequence（charter §3.1 区分）。
- 事件类型直接复用 `NativeAgentRuntimeEvent` 的 provider-neutral DTO 与 `DomainAgentRun*` 的 typed termination（不新造事件词汇）。
- 背压：每附着一个有界队列（count + bytes）；溢出 → 丢增量并置 `resnapshotRequired`，客户端重新 `attach`。host 不为任一客户端保留无界队列。【参】Prime attachment-local backpressure；charter §6.1 第 6 条
- 大快照：`snapshot_begin / snapshot_chunk(≤512 KiB) / snapshot_end`，host 侧从磁盘 snapshot 流式读，不在内存构造 history 大小对象。【参】

### 5.6 交互（permission / ask_user）

复用 M5 settlement 路径：每个 pending interaction 有内部 generation；**首个**到达的 `respond_interaction` 赢，其余按 stale 忽略并计数；超时按现有 Question Timeout。broker 的 provider 选择顺序改为：已附着且声明 `canPresent` 的客户端 → MCP elicitation（子进程连接）→ unavailable。零客户端附着时挂起等待，不自动 deny。【码】M5 spec "Interaction settlement"

权限**策略**（auto-approve 规则、tool preferences）作为会话配置随 `start` 传入 host；**决策**由附着客户端呈现给用户。策略不再依赖 GUI 存活。

---

## 6. 客户端 seam：`AgentSessionConnection`

对应 Prime `AgentConnection`。【参】`agent-connection.md`

```swift
protocol AgentSessionConnection: Actor {
    func attach(sessionID: UUID, resume: AgentSessionCursor?) async throws -> AgentSessionAttachResult
    func detach(sessionID: UUID) async
    func start(_ spec: AgentSessionStartSpec, operationID: UUID) async throws -> UUID
    func steer(sessionID: UUID, message: String, operationID: UUID) async throws
    func interrupt(sessionID: UUID, reason: String, operationID: UUID) async throws
    func respond(sessionID: UUID, interactionID: String, answer: AgentInteractionAnswer, operationID: UUID) async throws
    func stop(sessionID: UUID, operationID: UUID) async throws
    var events: AsyncStream<AgentSessionConnectionEvent> { get async }
}
```

- 两个实现：`InProcessAgentSessionConnection`（把今天的 `AgentTabSession` 执行栈包在后面；**仅用于 P1 过渡与测试组合**）与 `HostAgentSessionConnection`（§5 协议）。
- **边界不变量**（guardrail 强制，见 §9）：`AgentModeViewModel` / 视图不得直接引用 `ClaudeRustBackedNativeSessionAdapter`、`CodexAppServerClient`、`ACPAgentSessionController`、`CoreAgentSession`、`CoreAgentProviderSession`、socket 路径或协议类型。只有 `App/` 组合根可以知道具体 connection 实现。
- `AgentTabSession` 收缩为 presentation cache：transcript 投影、滚动/选中等 UI 本地状态、最新 snapshot 与 cursor。它不再持有 provider controller。
- 参照 Prime 的判据："若操作改变 agent 执行或持久会话状态，走 connection；若只改终端呈现或本地偏好，留在客户端。"

---

## 7. 所有权、持久化与恢复

### 7.1 会话所有权

- host 是会话事件日志、派生快照与会话元数据 `active` 状态的**唯一写者**；GUI 对 host 持有的会话只读。
- 复用 M5 围栏：上次 durable 处于 `active` 的记录不可被另一 runtime 认领；转移需先写 `inactive/interrupted/terminal` 再显式 fenced claim。host 重启后对 `active` 记录的处理：因写者已死（lease 释放为证），由新 host 先降为 `interrupted` 再 claim。【文】M5 spec "Session lifecycle, shutdown, and recovery"
- `DomainAgentRunLifecycleTracker` / `DomainAgentRunProcessIdentityState` / `DomainAgentRunTerminalCommitState` / `DomainAgentRunTerminalSettlementCoordinator` 原样搬进 host：它们已是无 UI 的值状态归约器，App 侧只剩投影。【码】`Sources/RepoPromptDomainRuntime/DomainAgentRun*.swift`

### 7.2 持久化格式：事件日志 canonical，快照派生【推，长期合同】

**事实源只有一个：append-only 事件日志。** 快照是可删除、可重建的派生缓存。这是与"快照为真、事件为优化"相反的选择，理由：

- 两份都可写就是两个事实源；ADR-0006 的 fail-closed schema 降级意味着格式**只能定一次**，P3 之后无法翻转。
- 事件日志天然承载 §5.4 的命令幂等记录、§5.5 的 replay 区间、§7.3 的崩溃恢复与 fork/branch（移 leaf 指针，不复制历史），四件事一个机制。【参】Prime append-only JSONL
- Rust 接手时只需实现"读/追加定长帧 + proto 解码"，不需要理解 Swift `Codable` 快照的字段语义。
- charter §18 第 4 条已允许在 Rust 侧重设计 Agent 会话格式；这里提前用 proto 定下来，Rust 到位时格式不再变。

**文件布局**（在既有 `AgentSessions/` 目录下）：

| 文件 | 性质 | 写者 | 格式 |
|---|---|---|---|
| `AgentSession-<uuid>.events` | **canonical**，append-only | host | `4B 长度 + 4B CRC32C + proto AgentSessionEvent`；文件头 `magic ‖ schemaVersion ‖ sessionID` |
| `AgentSession-<uuid>.snapshot` | 派生，可删 | host（按事件数/字节数阈值 compaction） | proto `AgentSessionSnapshot { throughCursor, state }`，原子替换 |
| `AgentSession-<uuid>.json` | **兼容读取**，派生，P4 后停写 | host | 现有 `AgentSession` Codable，供旧 `list_sessions`/`get_log`/sidebar 索引在过渡期继续工作 |

**读路径**：加载 = 读最新 `.snapshot`（若有且 schema 匹配）→ 从 `throughCursor` 之后重放 `.events` 尾部。快照缺失/损坏 → 全量重放。事件日志损坏（CRC 不符）→ 截断到最后一条完整记录，并向用户报告丢失区间；**不**用快照"修复"事件日志。

**写路径**：每条事件先 `write + fdatasync`（可按 turn 边界批量 sync，需在 SLO 内测量）再发布到订阅；`deliveryCursor` 即事件在日志中的序号。快照 compaction 在 turn 边界异步进行，失败只影响下次加载速度。

**Fork / 分支**（P4 之后）：新会话的事件日志以 `ForkedFrom{sessionID, cursor}` 起头，不复制父历史；读时按引用链解析。

**兼容性**：三个文件都带 schema 版本；旧 runtime 读新 schema fail closed（ADR-0006 第 3 条）。P3 cutover 时，尚未被 host 接管的既有 `AgentSession-*.json` 会话在首次被 host 打开时**一次性转换**为事件日志（`Imported{legacyDigest}` 起头事件 + 快照），原 `.json` 保留只读，不再作为写目标。

### 7.3 崩溃恢复矩阵

| 崩溃者 | 影响 | 恢复 |
|---|---|---|
| GUI | 无执行影响；附着丢失 | GUI 重启 → `attach(resumeCursor)`；host 从事件日志按 cursor 回放（`complete`），日志已 compaction 掉该区间则给快照 + 尾部（`partial`），generation 不同则全量快照（`unavailable`） |
| provider 子进程 | 该会话 run 终止（现有 typed termination 分类不变） | 现有 retry/resume 路径，不因 host 化改变 |
| host | 所有会话的 run 终止；provider 子进程作为 host 进程组成员被一并回收（reap 在 host 端）| lease 由内核释放；下一个客户端拉起新 host；新 host 从事件日志重建每个会话状态（最后一条完整记录为界），把 `active` 记录降为 `interrupted` 并 claim；用户可 resume（走 provider resume ID）。无 durable `CommandSettled` 的命令在下次同 `operationID` 查询时返回 `uncertain` |
| 两者同时 | 同上 | 同上 |

孤儿子进程防护：host 以自身为进程组 leader spawn provider，退出路径 `interrupt → reap`（复用今天 `applicationShouldTerminate` 里"先杀子进程再停 server"的顺序）；host 异常死亡时 provider 收到 SIGHUP/管道关闭，与今天 GUI 崩溃时的行为一致。

---

## 8. 阶段与门槛（ADR-0006 / ADR-0008 纪律）

两条并行轨道：**A 轨**交付会话存活（Swift 外壳），**B 轨**在 host 内把 Agent 语义权威搬进 Rust（charter Phase 6）。B 轨的每一步都以 A 轨定下的 proto 协议与事件日志为合同，不改客户端、不改磁盘格式。

| 阶段 | 交付 | 门槛 |
|---|---|---|
| **P0 决策** | ADR-0011 通过；登记 P3 SLO（attach p95 延迟、事件 fanout 吞吐、事件日志 fsync 对 turn 延迟的影响、host 常驻内存、host 崩溃率） | User 裁决 |
| **P1 seam** | `AgentSessionConnection` + `InProcessAgentSessionConnection`；`AgentTabSession` 去 controller；边界 guardrail | 行为零变化；全套 AgentMode 测试通过；guardrail 上 CI/preflight |
| **P2 合同冻结 + host 骨架** | `agent_host_v1.proto`（wire + 事件日志记录共用一份 schema）进 `agentry-proto`，Rust/Swift 双端 golden 测试；`agentry-mcp agent-host` 含 lease、握手、身份校验、事件日志读写、attach/snapshot/cursor、空闲退出；无生产接线 | **Rust crate `agent_session_log` 是事件日志读/写/校验/compaction 的唯一实现，Swift 外壳经同步有界 FFI 调用（`open/append/read_from/compact/close`，登记 `abi-v1.json` + `exports.txt`，fingerprint 轮换一次）**；协议帧与日志帧 fuzz 登记；跨进程 lease `SIGKILL` 测试；双向 fingerprint 拒绝测试；proto 与 `.events` 头格式在本阶段末**冻结** |
| **P3 cutover（A 轨）** | `HostAgentSessionConnection` 成为 GUI 生产路径；GUI 退出改为 detach；既有 `.json` 会话一次性导入；Sparkle 两阶段更新 | beta soak；SLO 达标；**删除** `InProcessAgentSessionConnection` 生产接线（测试可在进程内组装 host runtime，不留产品级开关） |
| **P4 多客户端（A 轨）** | `agent_run op: attach`；多窗口同会话；Agents View 最小版；停写兼容 `.json` | 多客户端 first-answer-wins 测试；背压丢弃 → resnapshot 测试 |
| **P6-a（B 轨，可与 P3/P4 并行）** | `DomainAgentRun*` 五个归约器迁 Rust（`agent_run_lifecycle` crate），host 内 Swift 只剩投影；差分测试 | 与现有 Swift 归约器 100% 差分一致后删除 Swift 实现（ADR-0006 无回退） |
| **P6-b（B 轨）** | transcript 归约与发布迁 Rust；事件发布直接由 Rust 写入事件日志并进入 `SubscriptionHub` | transcript 差分；`.events` 字节级一致 |
| **P6-c（B 轨）** | Codex/ACP 协议语义迁 Rust（`agent_provider` 从传输权威升为语义权威，与 `agent_claude` 对齐）；MCP 权限策略评估迁 Rust（决策呈现仍在客户端） | 现有 P7-1/P7-2 spec 的语义权威 gate |
| **P7 host 二进制换 Rust** | `bins/agentry-mcp`（Rust）实现 `agent-host` 模式：socket、lease、握手、fanout 用 Rust 重写（数百行）；Swift `RepoPromptMCP` 的 agent-host 入口删除 | 同一 proto、同一 `.events`、同一 lease 路径；老 Swift host 与新 Rust host 通过 §4.4 两阶段更新交接；客户端零改动 |
| **P5（条件）** | 每会话 worker 进程（拓扑透明不变量保证不 bump 协议） | 仅当 P3 崩溃率触发 §4.2 裁决点 |
| **P8** | GUI 缺席时 `--backend auto`→headless fence-claim 既有 workspace lease（headless direct）；GUI 在场不偷 lease | ADR-0011 addendum 2026-09-03 Accepted；inventory/search 不迁 host |

关键顺序约束：
- P2 之前不写任何 host 代码——合同先于实现。
- P6-a 不依赖 P3 完成：归约器是纯值状态，可以先在进程内以差分方式跑。
- P7 之前 B 轨必须全部完成；否则 Rust host 跑不完非 Claude 会话。
- 每阶段结束更新 `rust-agent-claude-v1.md:35-37` 等把交互式运行时钉为 GUI-scope 的文档。

---

## 9. 守卫与验证

- 新增 `Scripts/agent_session_boundary_guardrails.sh`：拒绝 `Features/AgentMode/{Views,ViewModels}` 引用 §6 列出的执行类型；拒绝 `Sources/RepoPromptMCP` 引入 AppKit（现有 `headless_runtime_guardrails.sh` 覆盖）。挂到 `make guardrails` → CI + `preflight.sh`。
- 协议：`agent_host_v1.proto` 进 `xtask generate --check` 的 byte-identical 生成物范围；新增 fuzz target `agent_host_frame_v1` 并登记。
- 焦点测试：`AgentSessionHostLeaseTests`（跨进程 SIGKILL）、`AgentSessionHostHandshakeTests`（fingerprint 拒绝、版本拒绝）、`AgentSessionHostAttachReplayTests`（complete/partial/unavailable 三态、generation 变更拒比）、`AgentSessionHostBackpressureTests`、`AgentSessionHostUpdateTests`（checkpoint 失败 → 不更新）。
- 能耗：P3 gate 加"host 空闲零唤醒"（`powermetrics`），沿用 charter §11.5。
- 观测：host 复用 `LoggingSystem` stderr handler + 现有诊断文件通道；panic 经同一 Sentry 通道上报（charter §11.7 单通道）。

---

## 10. 风险

| 风险 | 缓解 |
|---|---|
| 凭据：host 需要 provider 后端密钥（GLM/Kimi/custom backend）；不以 Keychain 为路径 | 已裁决（§11 第 4 条 / ADR-0011 addendum 2026-09-03）：envelope（0600 + `envelopeID`，兑换后零化删除）或 spawn 时已在进程环境中的密钥。Release 不得仅因 release 构建拒绝 envelope。缺 required secret fail closed，永不 Scripted echo。GUI 缺席且无 envelope/无继承环境 → fail closed |
| host 崩溃爆炸半径 = 所有会话 | §4.2 裁决点 + P5 条件阶段 |
| 混合版本（旧 host + 新 GUI） | 双向 fingerprint fail closed + 两阶段更新；不支持混合版本，与 ADR-0006 一致 |
| GUI 长期缺席时子进程工具调用失败 | P8 Accepted：`--backend auto` 在 GUI lease 空闲时走 headless 并 fence-claim 同一 flock |
| 认知成本：又一个进程、又一条协议 | 协议由 `agentry-proto` 单一作者点导出；命令词汇复用 `NativeAgentRuntimeControlling` 与 `agent_run` 已有操作；v1 命令面固定九条 |
| Swift 外壳被丢弃的成本 | 被丢弃的只有 socket/lease/fanout 胶水（§4.1.1 表第三行）；事件日志读写从 P2 起就是 Rust crate，归约器与语义是 Phase 6 本来要搬的 |
| 维护面：Prime 的 daemon 层 >500k 字符、30 文件，本项目维护者是 User + agent | 命令面九条封顶；调度/心跳/目标/side-question 明确排除；新增命令需 capability 协商并写入本文 |
| 事件日志 fsync 拖慢 turn | P0 登记 SLO；允许按 turn 边界批量 sync；compaction 异步 |
| 与未来 Rust `agentry-mcp` 二进制的关系 | host 是 `agentry-mcp` 的模式而非独立二进制；P7 用同一 proto/`.events`/lease 路径换二进制，客户端零改动 |

---

## 11. 已裁决项（2026-09-02，User 裁决：长期项目、Rust 为核心）

| # | 议题 | 裁决 | 理由 / 被否方案 |
|---|---|---|---|
| 1 | §4.2 单 host vs. per-session worker | **v1 单 host 进程**；host 内部从第一天以 `SessionRouter { sessionID → SessionExecutor }` 组织，worker 化只是给 `SessionExecutor` 换一个跨进程实现；崩溃率触发 P5 | 拓扑透明不变量已使 worker 化不动协议、不动磁盘。先付 per-session 进程成本换不到可测量收益，违反 charter §14.2 "只隔离问题域" |
| 2 | §7.2 事实源 | **事件日志 canonical，快照派生** | 格式在 ADR-0006 下只能定一次；"快照 canonical"会永久留下两个事实源，Rust 接手时还得理解 Swift `Codable` 字段语义 |
| 3 | §8 P2 事件日志实现语言 | **从第一天用 Rust crate `agent_session_log` 经 FFI 提供**。导出面：`agent_session_log_open / append / read_from / compact / close`，同步有界调用（ADR-0001 无 async 导出约束），登记 `abi-v1.json` + `exports.txt`，触发一次 fingerprint 轮换与 `xtask generate --check`。fuzz target `agent_session_log_frame_v1` 与协议帧 fuzz 同期登记 | 被否："先 Swift 写、P7 再换"。代价是同一格式两份实现、两份 fuzz、一次字节级差分迁移；收益只是省一次 FFI 导出变更（这是仓库已有的常规流程） |
| 4 | §10 凭据供给 | **2026-09-03 改裁：不以 Keychain 为路径。** 密钥只经（a）0600 `DomainCredentialEnvelope` + `envelopeID`（GUI start 前发布，host 兑换后零化删除）；（b）GUI/CLI spawn 时已在进程环境中的密钥（继承，不记日志）。Release 不得仅因 release 构建拒绝 envelope。缺 required secret fail closed，永不 Scripted echo。wire 永不出现明文。不启用 Keychain reader / access-group / Security.framework 读 provider API key | 原 2026-09-02「Release 读共享 Keychain」废止（User：「不需要用 keychains」）。envelope 是 portable 路径，不是 debug-only 退路 |
| 5 | P3 后进程内执行路径 | **删除生产接线，不留产品级开关**；`InProcessAgentSessionConnection` 只存在于 P1–P2 与测试组合 | ADR-0006 forward-fix only。保留开关 = 两条执行路径 × 两套持久化写者，正是 P8/多客户端最难处理的分叉 |
| 6 | §8 A/B 轨并行 | **P6-a 在 P2 合同冻结后立即启动，与 P3 并行**，目标是 P3 cutover 时 host 内的 run 生命周期归约已是 Rust；若未及，Swift 归约器先落 host，差分测试保证后续无感替换 | 归约器是纯值状态，差分测试不依赖 host 存在；越早迁越少 Swift 落进 host。唯一成本是并行占用 User + agent 带宽，故 P6-a 不设为 P3 的阻塞门槛 |

由这些裁决派生的硬约束：wire 与 `.events` 用同一 proto；`.events` 只有一个实现（Rust）；凭据字节不过 wire；GUI 不是任何东西的中介；host 内部结构从 v1 起按 router/executor 分层。

**编解码归属（实施时补充）**：Swift 侧不引入 SwiftProtobuf。wire 与事件日志的 proto 编解码只有 Rust 一个实现（`agentry-proto` 内 prost 生成物，经 `xtask generate --check` 字节一致），Swift 外壳与 Swift 客户端通过既有 UniFFI 边界以类型化记录拿到已解码消息。UniFFI 仍只是进程内桥，不是 wire 格式（charter §14.2 约束不变）。这使 P7 换 Rust 二进制时编解码零迁移，也避免了 ADR-0007 下新增一条 Swift 供应链依赖。

---

## 12. 实施进度

| 阶段 | 状态 | 说明 |
|---|---|---|
| P0 | 完成 2026-09-02 | ADR-0011 Accepted；SLO 登记随 P2 交付 |
| P1 seam | 完成 2026-09-03（P1.5 收尾完成 2026-09-03） | `Features/AgentMode/Connection/` 落地 `AgentSessionConnection` + `InProcessAgentSessionConnection`；`AgentTabSession` 不再持有 provider controller（执行态经 `connectionAttachment` 停靠，guardrail 禁止 Views/ViewModels 访问）；`Scripts/agent_session_boundary_guardrails.sh` 进 `make guardrails`。P1.5 落地：seam 签名按 proto `CommandResponse` 镜像（`start→AgentSessionStartResult(SessionStarted)`、`steer→AgentSessionSteerResult(Steered)`、`interrupt→AgentSessionInterruptResult(InterruptResult.Outcome)`、`respond→AgentSessionRespondResult(InteractionResponded.Disposition)`、`stop(reason: StopReason)→AgentSessionStopResult(Stopped)`；`AgentSessionSendOutcome` 无损映射 `NativeSendOutcome?`），返回值与 `commandSettled` 载荷同值；VM 热路径 `startAgentRun`（含 Codex fallback 提交上下文经 `AgentSessionStartSpec.executionContext` 透传）、`cancelAgentRun`/全部 `cancelRun` 调用点、窗口/tab 关闭 `stop`、approval/elicitation/hook-review/ask-user/user-input/permissions `respond` 经 connection 进入 `InProcessAgentSessionExecutor`；MCP `agent_run` 是同一 connection 的第二客户端（`cancel` 直接 `interrupt`；`steer`/instruction 走 `connection.steer`；`respond` 走 `connection.respond`；`start` 仍先做 presentation 再 `connection.start`）。`AgentModeExecutionEventObserving` 把 Claude `NativeAgentRuntimeEvent` 与 barrier 终态 `DomainAgentRunTerminalOutcome` 镜像到 `.runtime/.runTerminated`，VM `events` 消费者维护 `latestConnectionSnapshot/latestConnectionCursor`；幂等日志每连接 LRU（容量 1024）+ stop/generation 轮换按 session 逐出；guardrail 第 10 条禁止 presentation 直接 `runService.startRun/cancelRun`、`*Coordinator.submitApprovalDecision`。仍绕过 seam（同步契约，P3 处理）：活动 run 的 GUI composer steering 队列入队与 MCP dispatch 的队列 flush（`submitQueued*Steering`）、instruction-wait continuation 由 GUI composer 恢复、worktree merge review（workspace 域）、native slash 控制面、未绑定 sessionID 的 tab 关闭回退、presentation hook 的直接事件投递（seam 镜像是附加的） |
| P2 合同 + host 骨架 | **合同 + host 骨架已落地 2026-09-03**；无生产 GUI 接线 | 合同半（2026-09-03）：`rust/crates/proto/schema/agent_host_v1.proto`（握手、九条命令、事件/快照流、交互、事件日志记录；`PROTOCOL_VERSION = 1`，文件头声明冻结）；prost 生成物 `rust/crates/proto/src/generated/agent_host_v1.rs` 由 xtask（protox + prost-build，无系统 protoc）生成并入 `xtask generate --check` 字节一致范围；帧编解码/上限/`argument_fingerprint` 在 `agentry_proto::agent_host`；新 crate `rust/crates/agent_session_log`（`.events`/`.snapshot` 头格式 `SCHEMA_VERSION = 1`，CRC32C 记录，torn-tail 截断上报，快照原子替换，未知版本 fail closed，fixtures + proptest）；UniFFI 导出 `AgentHostProtocolV1.*`（12）与 `AgentSessionLog.*`（9）及全部 `AgentHost*V1` 类型化镜像，登记 `abi-v1.json` + `exports.txt`，fingerprint 已轮换一次；fuzz `agent_host_frame_v1` / `agent_session_log_frame_v1` 登记进 CI；六项 SLO 登记于 `slo-v1.json#agentSessionHostV1`。host 骨架半：`agentry-mcp agent-host [--idle-exit-seconds N]`（`Sources/RepoPromptMCP/AgentSessionHostCommand.swift`，AppKit-free）；每用户 `flock` lease（`agent-host-v1.lock`）+ Unix socket（0700 目录，仅持有 lease 后 unlink 陈旧 socket）；`SessionRouter { sessionID → SessionExecutor }` 仅挂 P2 stub `AgentSessionScriptedExecutor`；握手双向 `buildFingerprint` + 可执行文件身份（DEBUG `AGENTRY_AGENT_HOST_ACCEPT_ANY_PEER=1` 可关）；九条命令经 `.events` 记 `CommandAccepted`/`CommandSettled`；attach replay `complete\|partial\|unavailable` + chunked snapshot；每附着有界 fanout → `resnapshotRequired`；`prepare_update` 全会话 checkpoint（任一失败则拒绝）；空闲退出（默认 300s，`0` 关闭）+ `ProcessInfo.beginActivity`；重启围栏把 `running`/`active` 降为 `waitingForInput` + statusText `interrupted`（proto 无独立 `interrupted` 状态）。共享 `AgentSessionHostClient`（connect / hello-welcome / 九条命令 / `events` / `reconnect`+`resumeCursor` / spawn-if-absent + lease-wait），协议层，无 `AgentModeViewModel`。测试：`AgentSessionHostLeaseTests`（含跨进程 `SIGKILL`）、`HandshakeTests`、`AttachReplayTests`、`BackpressureTests`、`UpdateTests`、`IdempotencyTests`。偏差：镜像未知枚举值按 fail closed 拒绝而非映射 `_UNSPECIFIED`；编解码/日志导出不携带 `RuntimeIdentity`；重启降级用 `waitingForInput` 代替缺失的 proto `interrupted`；P2 生产路径仍是 stub executor（P3 换 provider 实现） |
| P6-a（B 轨） | **Rust 归约器 + 差分测试已落地 2026-09-03**；Swift 归约器保留（删除待 GUI cutover 后） | 落地：`rust/crates/runtime/src/agent_run_lifecycle/`（`runtime` crate 内模块而非独立 crate，避免改动 `rust_ffi_guardrails.py` 冻结的 workspace 成员表）五个纯值归约器 `LifecycleTracker` / `ProcessIdentityState` / `TerminalCommitState` / `TerminalSettlementCoordinator` / `SemanticAuthority`（后者含 `DomainAgentRunExecutionCore` 的纯分类半边 `classify_execution` / `classify_provider_execution`），无 I/O、无时钟、UUID 与时间全部为输入；`proto.rs` 双向映射 `agent_host_v1` 的 `LifecycleStage`/`RetryIntent`/`EpochTransitionKind`/`TerminalOutcome`/`TerminationSignal`/`TurnEpoch`（`_UNSPECIFIED` fail closed），`canonical.rs` 固定键序 JSON 供跨实现比对；38 个单元测试镜像全部 Swift 用例 + 9 个 proptest 不变量（终态吸收、fence 拒绝陈旧代际、tombstone 有界 FIFO、语义分类结构化）。UniFFI 导出五个对象 `AgentRunLifecycleTrackerV1`（19）/ `AgentRunProcessIdentityStateV1`（8）/ `AgentRunTerminalCommitStateV1`（11）/ `AgentRunTerminalSettlementCoordinatorV1`（10）/ `AgentRunSemanticAuthorityV1`（6）及 `AgentRun*V1` 类型化镜像，新增 `CoreError::AgentRunLifecycleInvalidRequest`（非法 UUID 文本），登记 `abi-v1.json#agentRunLifecycleV1` + `exports.txt`，fingerprint 轮换两次；Swift 桥 `Sources/AgentryCoreBridge/CoreAgentRunLifecycle.swift`。差分：`Tests/RepoPromptDomainRuntimeTests/DomainAgentRunRustDifferentialTests.swift`（+`…Support.swift`）复演全部 Swift 归约器测试场景（8 tracker / 6 terminal-commit / 6 settlement / 3 semantic+execution）并以 SplitMix64 种子语料（默认 seed `0xA6E75EED00000006`，`AGENTRY_P6A_DIFFERENTIAL_SEED/SCALE` 可复现/放大）驱动双实现：tracker 10 240、terminal-commit 5 760、process-identity 3 840、settlement 3 840 步随机迁移 + 语义 400 样本 + 85 个穷举终止信号 × 执行分类 520 组，每步比对返回值、可观测状态与 canonical JSON，100% 一致，未发现 Swift 侧缺陷。偏差：归约器直接使用 proto 枚举词汇但 `TurnEpoch` 用完整 Domain 结构（proto `TurnEpoch` 缺 runtime/session/activation/registration 字段，`to_proto()` 有损，仅供日志投影，schema 冻结未改）；不解码任意字节，按设计走 property-test-only，无新增 fuzz target。未落地：Swift 归约器删除与 GUI 热路径切换（依赖 P3 cutover） |
| P6-c（B 轨） | **Rust Codex/ACP 协议语义 + MCP 权限评估已落地 2026-09-03**；Swift 语义代码与 GUI/host 热路径保留（rewire 待后续，同 P6-b leftover publish） | 落地：`rust/crates/runtime/src/agent_provider_semantics/`（`runtime` crate 内模块，不新增 workspace member）三块纯函数 / 值归约：`permission`（`PermissionPolicy`+`ToolPreference`+pending request → `allow/deny/ask`，RepoPrompt auto-approval overlay；`DECLINE_UNATTENDED`→ask，host 零客户端等待不在此层）、`acp`（session-update 归一化到冻结 `RuntimeEvent`、option policy、`stopReason` 终态吸收）、`codex`（server-request 分类、approval/permissions parse、model collapse/negotiate、turn 吸收）。无 I/O、无时钟、id 全为输入。UniFFI 三个对象 `AgentPermissionPolicyEvaluatorV1` / `AgentProviderAcpSemanticsV1` / `AgentProviderCodexSemanticsV1`，复用既有 `AgentHost*V1`，无新 `CoreError` 变体，登记 `abi-v1.json#agentProviderSemanticsV1` + `exports.txt`，fingerprint 轮换一次。Swift 桥 `Sources/AgentryCoreBridge/CoreAgentProviderSemantics.swift`。差分：`Tests/RepoPromptDomainRuntimeTests/AgentProviderSemanticsRustDifferentialTests.swift`（+Support）命名夹具（Grok 归一化、RepoPrompt auto-approval、Codex classify/collapse/approval、权限策略）+ SplitMix64 种子语料（默认 seed `0xC6E75EED00000006`，`AGENTRY_P6C_DIFFERENTIAL_SEED/SCALE`）；live oracle `Tests/RepoPromptTests/AgentMode/AgentProviderSemanticsLiveOracleDifferentialTests.swift` 对照产品 Swift。不解码未信任字节（JSON-RPC 仍归 `provider_json_rpc`），property-test-only，无新增 fuzz。proto 缺口：`RuntimeEvent` 无 turnStarted / requestUserInput / mcpElicitation；`PermissionEvalReason` 不在 proto；`DECLINE_UNATTENDED` 语义与 host wait 分家。未落地：GUI 热路径仍用 Swift 语义副本（rewire 待后续）。**P3 leftover（2026-09-03）**：host `ProviderAgentSessionExecutor` 已改调这些 P6-c 对象做 classify/normalize/evaluate/negotiate；呈现与 `agent_provider` 传输仍在原处。 |
| P6 leftover（Codex bash / file-change 合成） | **Rust 值归约已落地 2026-09-03**；Swift 产品代码与 GUI/host 热路径保留（rewire 待后续） | 落地：同 crate 模块 `codex_lifecycle`，一对一移植 leftover `CodexNativeSessionController` 的 `FileChangeStreamState` + `parseFileChangeLifecycleEvent` / `parseFileChangeOutputDeltaEvent`，以及 item 列表上的 `applyCommandExecutionRunningUpdate` + 输出 sanitizer + `stableInvocationID`（不移植 GUI live-bash / MCP tool / rollout 对账）。UniFFI 对象 `AgentProviderCodexLifecycleV1`（+ Event/BashItem/RunningUpdate/RunningApply 记录），无新 `CoreError` 变体，与 P7 一次 fingerprint 轮换。Swift 桥仍在 `CoreAgentProviderSemantics.swift`。差分：`Tests/RepoPromptDomainRuntimeTests/AgentProviderCodexLifecycleRustDifferentialTests.swift`（+Support）命名夹具（start/delta/complete、late-delta 抑制、restart 清终态、unique bash running update、CSI/backspace、UUID vs hashed invocation）+ SplitMix64 语料（默认 seed `0xD6E75EED00000006`，`AGENTRY_P6_LIFECYCLE_DIFFERENTIAL_SEED/SCALE`）；JSON 按解析对象 + 规范化键序比对（Swift `jsonString` pretty、Rust compact）。未落地：GUI/host 切到该对象。 |
| P6-b（B 轨） | **Rust transcript 归约器 + 差分测试已落地 2026-09-03**；**publish cutover 完成 2026-09-03**（Swift host 热路径改折 Rust） | 落地：`rust/crates/runtime/src/agent_session_transcript/`（`runtime` crate 内模块，紧邻 P6-a `agent_run_lifecycle`）纯值归约器 `SessionState`，一对一移植 `AgentSessionHostSessionState`（event + cursor → transcript / pending interactions / command 幂等表 / 派生 `AgentSessionSnapshot`），无 I/O、无时钟、cursor 与时间全部为输入；`canonical` 固定键序 JSON 供跨实现比对。UniFFI 导出一个对象 `AgentSessionTranscriptReducerV1`（18：placeholder / fromSummary / fromSnapshot / reset / apply / setGeneration / setAttachedClientCount / snapshot / summary / hostOwnedSummary / lastCursor / hasMetadata / isTerminal / hasLiveRun / transcript / pendingInteractions / unsettledOperations / canonicalState），复用既有 `AgentHost*V1` 镜像，无新 `CoreError` 变体，登记 `abi-v1.json#agentSessionTranscriptV1` + `exports.txt`，fingerprint 轮换一次；Swift 桥 `Sources/AgentryCoreBridge/CoreAgentSessionTranscript.swift`。差分：`Tests/RepoPromptDomainRuntimeTests/AgentSessionTranscriptRustDifferentialTests.swift`（+`…Support.swift`）复演全部 Swift 归约器分支（16 个场景）并以 SplitMix64 种子语料（默认 seed `0xB6E75EED00000006`，`AGENTRY_P6B_DIFFERENTIAL_SEED/SCALE`）驱动双实现 2 048 步，每步比对 snapshot、可观测标志与 canonical JSON。**Publish leftover（2026-09-03）**：Swift `AgentSessionRouter` 经 `AgentSessionHostFoldedState` 把 live append / recover replay / `compact` 快照切到 `CoreAgentSessionTranscriptReducer`；`.events` 仍只由 `AgentSessionLog` FFI 写（先 append 再 fanout，design §7.2）。进程内无 `SubscriptionHub`——附着客户端走既有 outbound queue，订阅源是刚写入的日志记录。夹具语料（`AgentSessionTranscriptPublishAgreementTests`）断言：同一事件序列两份 `.events` 字节一致；Rust/Swift snapshot 经 `encodeSnapshot` 字节一致；从 snapshot+尾部重放后 canonical JSON 与内存折一致。Swift `AgentSessionHostSessionState` **未删**：生产 host 不再调用，仅作差分 live oracle（ADR-0006 无产品回退开关；删除待测试不再需要它）。偏差：`TranscriptEntry.tool_*` / `reasoning` 与 `StreamResult` 的 tool/reasoning 项 Swift 从未折叠（proto 冻结不改）；`latestAssistantPreview` 截断 Rust 按 Unicode scalar、Swift 按 `Character`（BMP/ASCII 一致）；`TurnEpoch` 仍是 P6-a 的有损投影。command/interaction 查找因 UniFFI 未导出 map 而在 host 侧建 RAM 索引（同一事件，不是第二套 transcript 折）。 |
| P7 host 二进制换 Rust | **客户端 cutover 完成 2026-09-03** | GUI/`AgentSessionHostClient` 只 spawn Rust `bins/agentry-mcp agent-host`。为避免与 Swift MCP CLI 产品同名抢路径，debug/`make dev-build` 把 Cargo 产物（`.build/cargo/aarch64-apple-darwin/<profile>/agentry-mcp`）装进 bundle 为 `Contents/MacOS/agentry-agent-host`；解析器拒绝 SwiftPM `.build/**/agentry-mcp`。argv 仍是 `agent-host`。生产 spawn 环境：`AGENTRY_AGENT_HOST_LIVE=1` + `AGENTRY_HOST_BUILD_FINGERPRINT`（GUI UniFFI fingerprint）+ `AGENTRY_AGENT_HOST_MCP_BACKEND=auto`，继承进程 PATH/凭据；**不**设 `AGENTRY_AGENT_HOST_READ_KEYCHAIN`。测试强制 `LIVE=0` 以免 echo 冒充回合。已删 `Sources/RepoPromptMCP/AgentSessionHostCommand.swift` 与 Swift CLI `agent-host` 模式（该 CLI 再收到 `agent-host` 以 usage 2 拒绝）。Sparkle 仍是已运行 host 上 `prepare_update`（全会话 checkpoint）成功才 `shutdown`，失败不替换/不停 host；旧 Swift host 与新 Rust host、以及随后 Rust→Rust，走同一条两阶段（握手仍在替换前、指纹仍匹配时完成）。同一 proto、同一 `.events`、同一 lease 路径。无 resume 的首次 attach 与 Swift 一致，推 snapshot（design §5.4）。**凭据 leftover（2026-09-03 addendum）**：debug 与 release 都把 secret 写成 0600 一次性信封，wire 只带 `envelopeID`；host `launch.rs` 兑换后零化删除，或继承 spawn 环境。不以 Keychain 为路径。`LIVE=1` + 缺 required secret（GLM/Kimi/custom）fail closed，不回落 Scripted echo；官方 Claude/Codex 无 API key 仍走 CLI 登录。host 全局 mutex 已在 executor I/O 前释放（accept 只做非阻塞 + idle/shutdown 短锁；`Family::Claude` 的 `can_use_tool` 已接 `request_ask`）。 |
| P3 GUI cutover | **完成 2026-09-03** | `HostAgentSessionConnection` 为 GUI 生产路径（`WindowStateComposition` 构造，无产品开关）；`InProcessAgentSessionConnection` 仅测试。`agentry-mcp agent-host` 生产 factory 换 `ProviderAgentSessionExecutor`（DomainRuntime；Claude=`CoreAgentSession`，Codex/ACP 经 `CoreHostedRuntimeSession` 拉起进程；完整 Codex/ACP 协议语义仍在 GUI coordinator）。GUI 退出 `detachAll`，不 `stop`/不杀 provider；窗口关闭同样 detach。"Stop all agents" 仍走 `shutdownAllAgentSessions`。`prepare_update` 经 Sparkle `shouldPostponeRelaunchForUpdate`：失败不替换/不停 host；成功后 `shutdown` 以便新二进制拉起。既有 `AgentSession-*.json` 首次 host 打开写 `Imported{legacyDigest}` + `.events`，`.json` 保留。测试：`HostAgentSessionConnectionTests`（attach replay / uncertain / resnapshot / quit=detach / prepare_update refuse / json import）。**P3 leftover（2026-09-03）**：host `ProviderAgentSessionExecutor` 现已驱动 Codex app-server / ACP JSON-RPC 回合（initialize → thread\|session → turn/prompt；P6-c 对象 classify/normalize/evaluate/negotiate；`ask` 含 `DECLINE_UNATTENDED` 零客户端挂起等待、不自动 deny；脚本化 transport 单回合测试）。**cwd leftover 已收（2026-09-03）**：冻结 proto 仍无 cwd 字段；GUI `startAgentRun` 把 workspace/worktree 根写成 path-shaped `worktree_id`，首次 spawn 还可叠 `AGENTRY_AGENT_HOST_WORKING_DIRECTORY`。仍缺：ACP authenticate 供应商偏好、Codex 图片附件、GUI live-bash/hook-trust/模型目录热路径。 |
| P4 多客户端 | **完成 2026-09-03** | MCP `agent_run op: attach` / `detach`（服务层 + 正式 catalog 广告 `resume_cursor`/`resume_generation`，digest `4344bfe4…`）；第二客户端 resume cursor + wait/poll 兼容；多窗口同 `sessionID`（每窗自己的 `HostAgentSessionConnection` + 呈现缓存，执行在 host）；Agents View 最小：sidebar `Host` 段 `list_sessions` → attach；停写 `AgentSession-*.json`（读 + `AgentSessionLegacyJSONImport` 保留）；交互 first-answer-wins 跨客户端并计数 `staleInteractionResponseCount`；背压丢弃 → `resnapshotRequired` 双客户端测试。MCP 原 fence「active but is not controlled by this MCP handle」改为 attach。P5 仍条件未开始。冻结 proto 的 `Steer` 无 envelope 字段：凭据只在 `Start`/`SessionSpec` 绑定；信封是一次性的，host 重启后不能重发已兑换信封（需新 start 或继承环境）。 |
| P8 workspace lease when GUI absent | **Accepted + 落地 2026-09-03** | `agentry-mcp --backend auto` 以 `DomainWorkspaceAuthorityLease` peek 为 GUI 在场权威（`mode == "app"` → 固定 `.app`，不偷 lease；unused → 既有 socket probe，否则 headless fence-claim 同一 flock）。`RepoPromptMCPServerConfiguration.repoPrompt` 与 host spawn `AGENTRY_AGENT_HOST_MCP_BACKEND=auto`。Rust `agent-host` 生产不 claim（`claim_workspace_authority` 默认 false）；测试可 claim/拒绝 GUI/shutdown 释放。inventory/search 仍在 GUI FFI。凭据：envelope + 继承环境，无 Keychain。 |

---

## 参考

- Prime Agent（`PrimeIntellect-ai/prime-agent` @ `0ba0423c`）：`packages/coding-agent/docs/daemon.md`、`agent-connection.md`、`architecture.md`、`src/modes/daemon/daemon-protocol.ts`、`src/core/session-lease.ts`、`src/modes/rpc/jsonl.ts`
- Charter：`docs/architecture/agentry-rewrite-charter.md` §2.2、§6.1、§7.2–7.3、§11.5–11.6、§14.2、§18 第 4/9 条
- ADR-0006（beta soak / fail-closed schema / 单写者 lease）、ADR-0008（基准 gate）、ADR-0009（Protobuf 数据面）
- M5 spec：`docs/spec/headless-mcp-domain-runtime-m5-ai-agent-interaction.md`
- P18 spec：`docs/spec/headless-mcp-domain-runtime-p18-agent-run-process-identity-authority.md`
- 现状梳理：`docs/investigations/architecture-full-flow-2026-09-01.md` §5.4
