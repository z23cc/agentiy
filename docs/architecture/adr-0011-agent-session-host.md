# ADR-0011: Agent Session Host — Agent Mode 会话执行迁出 GUI 进程，仅隔离 Agent 域

**Status:** Accepted（2026-09-02，User 裁决；设计文档 §11 六项裁决同日定案，实现按 §8 双轨启动）。**Addendum Accepted 2026-09-03**（凭据：不以 Keychain 为路径；P8：GUI 缺席时 fence-claim 既有 workspace lease）。
**Date:** 2026-09-02
**Decision owner:** User
**Design:** [`docs/spec/agent-session-host-v1-design.md`](../spec/agent-session-host-v1-design.md)

## Context

Agent Mode 会话今天完全由 GUI 进程持有：`AgentModeViewModel` → `AgentTabSession` 拥有 transcript、run state 与 provider controller；`applicationShouldTerminate` 在退出时显式 `shutdownAllAgentSessions()` 杀掉所有 provider 子进程（`AppDelegate.swift:239-268`）。MCP `agent_run` 对 GUI 已激活的 run 明确拒绝接管（`AgentRunMCPToolService.swift:1106-1110`）。结果是 GUI 的崩溃、退出与 Sparkle 更新都会终止全部运行中的 agent，且同一会话不能被第二个窗口或 CLI 附着。

Charter §14.2 把"UI 重启时 Agent/session 必须继续存活"与"多前端共享 authority"列为允许引入本地 RPC/daemon 的触发条件，并约束"优先只隔离问题域，而不是把整个 core 预先改为 daemon；外部进程协议必须使用项目自有 schema，不复用 UniFFI 内部格式"。§18 第 9 条——何种指标正式触发 Agent runtime 的 daemon 化——一直未裁决。

Prime Agent（`PrimeIntellect-ai/prime-agent`，MIT，2026-08 开源）以 supervisor / per-root worker / attach-detach client 的拓扑解决了同一问题；其事件游标、命令幂等、会话 lease、attachment-local 背压、两阶段更新等原语与 Agentry 已有的 `SubscriptionHub` cursor、`OperationID` 幂等、`DomainWorkspaceAuthorityLease`、M5 会话所有权围栏逐一对应。Agentry 缺的是把这些原语用于跨进程边界的那一层，而非原语本身。

## Decision

1. **触发条件视为满足（回答 §18 第 9 条）。** 引入 daemon 的依据不是崩溃率指标，而是产品需求：Agent 会话必须在 GUI 重启后存活，并允许多客户端附着。崩溃率指标改为决定**隔离粒度**（见第 6 条），不再决定是否 daemon 化。
2. **只隔离 Agent 域。** 新增按用户驻留的 **Agent Session Host** 进程，持有 Agent Mode 会话的执行、run 生命周期权威（`DomainAgentRun*` 归约器原样迁入）与会话持久化写权。`CoreRuntime` 其余部分、搜索/codemap/inventory 等权威**不迁移**（ADR-0008）。workspace **authority lease** 仍是既有单写者 `DomainWorkspaceAuthorityLease` flock：GUI 在场时 tools 走 `agentry-mcp --backend auto`→`.app` proxy，不偷 GUI lease；GUI 缺席时同一 `--backend auto`→`.headless` 路径按 CLI headless 规则 fence-claim 该 lease（P8，见 addendum）。不把 inventory/search 迁入 host。
3. **长期合同是 wire 协议与落盘格式，不是 host 实现。** 二者由 `agentry-proto` 同一份 `agent_host_v1.proto` 定义（ADR-0009），从第一天按"Rust 二进制可原样接手"设计：不透明 ID、无本地路径、无 Swift/Rust 内部类型名、可加字段/不兼容改动 bump 版本。**协议对进程拓扑透明**：客户端只按 `sessionID` 寻址，`generation` 为不透明字节串，worker 进程是否存在在 wire 上不可见。
4. **host 是 `agentry-mcp` 的一个模式（`agentry-mcp agent-host`），不是新二进制，不使用 launchd/XPC；v1 外壳为 Swift 是约束而非选择，且被指定为 charter Phase 6 的落地场。** Rust 今天只拥有 Agent 域的进程/传输权威，Codex/ACP 语义、transcript、run 生命周期归约、持久化仍在 Swift，纯 Rust host 跑不完非 Claude 会话。因此：(a) 会话事件日志的读/写/校验/compaction 从 P2 起就是 Rust crate `agent_session_log`（`open/append/read_from/compact/close` 同步有界导出，登记 `abi-v1.json` + `exports.txt`），Swift 外壳经 FFI 调用，`.events` 从未有过第二个实现；(b) `DomainAgentRun*` 归约器、transcript 归约、Codex/ACP 语义、权限策略评估按 Phase 6 逐个迁 Rust，**每一步都在 host 进程内进行**（无 `@MainActor`，受 `headless_runtime_guardrails.sh` 约束）；(c) B 轨完成后 host 二进制换为 Rust `bins/agentry-mcp`，同一 proto、同一 `.events`、同一 lease 路径，客户端零改动。被丢弃的 Swift 只有 socket/lease/fanout 胶水。host 由任一客户端按需拉起为独立进程组，以 `flock` lease 收敛为每用户单实例，空闲超时自行退出。
5. **会话持久化为事件溯源：append-only 事件日志是唯一事实源，快照是可删可重建的派生缓存。** 事件日志同时承载命令幂等记录（`CommandAccepted`/`CommandSettled`）、attach replay 区间、崩溃恢复与 fork（移 leaf 指针）。现有 `AgentSession-<uuid>.json` 降为过渡期兼容读取输出，首次被 host 打开的旧会话一次性导入，P4 后停写。三个文件带 schema 版本，旧 runtime 读新 schema fail closed（ADR-0006 第 3 条；charter §18 第 4 条授权重设计）。选择理由：格式在 ADR-0006 下只能定一次，"快照 canonical + 事件优化"会在 cutover 后永久留下两个事实源。
6. **传输为本机 Unix socket + 长度前缀 Protobuf 帧；不复用 UniFFI 内部格式，不复用 MCP JSON-RPC。** 握手做**双向** build fingerprint 与可执行文件身份校验，不匹配 fail closed；混合版本不受支持。事件采用 `{generation, deliveryCursor}`，attach 原子返回快照与游标并声明 replay 为 `complete | partial | unavailable`。命令以调用方预生成的 `operationID` 幂等，无 durable 结果时返回 `uncertain`，不盲重放。**v1 命令面固定九条**（list/attach/detach/start/steer/interrupt/respond/stop/prepare_update+shutdown）；调度、心跳、目标、side-question 等不进 host 协议。
7. **UI 不得拥有执行。** GUI 通过 `AgentSessionConnection` seam 成为客户端；`AgentTabSession` 收缩为 presentation cache。`Features/AgentMode/{Views,ViewModels}` 引用任何 provider 执行类型、core session 句柄、socket 路径或协议类型由 guardrail 拒绝，挂入 `make guardrails` → CI 与 `preflight.sh`。
8. **v1 为单 host 进程；每会话 worker 为条件阶段，且因第 3 条的拓扑透明不变量不需要协议 bump。** host 内部从 v1 起按 `SessionRouter { sessionID → SessionExecutor }` 分层，worker 化只替换 `SessionExecutor` 实现。P3 beta soak 前登记 host 崩溃率 SLO（ADR-0008）；若 host 每周非零崩溃且波及 >1 个并发会话，进入每会话 worker 进程阶段，否则不做。
9. **~~host 直接读 Keychain~~（2026-09-03 废止）。** 凭据只经两条路径到达 host：（a）0600 `DomainCredentialEnvelope` 文件 + `Start`/`SessionSpec.envelopeID`（GUI 在 start 前发布；host 兑换后零化删除）；（b）GUI/CLI spawn host 时已经在进程环境里的密钥（继承，不记日志）。不启用 Keychain reader，不加 Keychain access-group entitlement，不在 host 或 GUI publish 路径调用 Security.framework 取 provider API key。Release **不得**仅因 release 构建拒绝 `credentialEnvelopeId`。缺 required secret（GLM/Kimi/custom）fail closed，永不 Scripted echo。
10. **GUI 退出序列修订 charter §11.6。** `applicationShouldTerminate` 对 host 持有的会话执行 detach 而非 shutdown；"Stop all agents" 成为显式用户操作。Sparkle 更新采用两阶段（host 对全部活跃会话 checkpoint 成功后才退出并被替换；任一失败则不更新 host）；Swift host → Rust host 的交接走同一机制。
11. **Cutover 遵守 ADR-0006/0008，两条轨道并行。** A 轨（会话存活）：seam → 合同冻结与 host 骨架 → cutover → 多客户端。B 轨（Phase 6 语义迁 Rust，在 host 内进行）：归约器 → transcript → Codex/ACP 语义与权限策略 → 换 Rust 二进制。合同先于实现：P2 冻结 proto 与事件日志头格式前不写 host 代码。B 轨第一步（归约器迁 Rust）在 P2 冻结后立即启动、与 P3 并行，目标是 cutover 时 host 内 run 生命周期归约已是 Rust，但不作为 P3 阻塞门槛。beta soak，forward-fix only；**P3 之后删除进程内执行的生产接线，不保留产品级开关**，进程内路径仅用于测试组合。
12. **workspace/search/inventory 等延迟敏感域永久留在 GUI 进程内的 FFI 边界上。** ADR-0008 实测跨边界往返在 10 万文件规模下慢 50–80 倍；"整个 core 做成 daemon、GUI 纯客户端"不是本项目的终态。~~GUI 缺席时 host 取 workspace lease 留待独立 ADR~~（2026-09-03 废止，见 addendum P8）：只把 **workspace authority lease** 借给 agent 工具 mutation；inventory/search 仍走 GUI FFI。

## Consequences

- Agent 会话与 GUI 生命周期解耦；GUI 崩溃/更新不再终止 run；同一会话可被多窗口与 CLI 附着（`agent_run` 新增 `attach`）。
- 引入一个新进程、一条新协议、一个新 lease 与一种新持久化格式（append-only 事件日志 + 派生快照），全部落在既有 fail-closed 守卫体系下（byte-identical 生成物、fuzz 登记、guardrail、preflight）。Agent 会话的磁盘真相从 Swift `Codable` 整文件重写变为 proto 事件日志，这是一次一次性、不可逆的格式变更。
- Agent 域成为第一个"Swift 外壳 + Rust 合同"的跨进程域：Phase 6 的每一步 Rust 语义迁移都有了一个没有 UI 的落地进程，不再需要在 `@MainActor` 的 GUI 里做 cutover。Swift 外壳最终被丢弃的部分只有 socket/lease/fanout 胶水。
- 命令面封顶九条与拓扑透明不变量共同约束了维护面：新增命令走 capability 协商并回写设计文档；per-session worker、worker 直连、远程传输都可以在不 bump 协议的前提下追加。
- P8：GUI 缺席时，`--backend auto` 经既有 `DomainWorkspaceAuthorityLease` flock fence-claim 为 headless direct（单写者、冲突 fail closed）；GUI 在场（lease `mode == "app"`）时 auto 固定为 `.app` proxy，不偷 lease。GUI 重开走既有 proxy reconnect/replay，不双写。host 生产 spawn **不**自己 claim 该 flock（`HostConfig.claim_workspace_authority` 默认 false），避免与 headless MCP 抢写者。
- 凭据：envelope + 继承环境；无 Keychain access-group / Security.framework 读密钥。缺 required secret fail closed。GUI 缺席且无 envelope、无继承环境时，需要新凭据的会话仍 fail closed。
- `agent_session_log` 导出进入 FFI 合同：一次 fingerprint 轮换、`exports.txt`/`abi-v1.json` 登记、新增 fuzz target；这是仓库既有流程，不是新机制。
- 事件日志 fsync 对 turn 延迟的影响需在 P0 登记 SLO；允许按 turn 边界批量 sync。
- 需同步修订 `rust-agent-claude-v1.md` 等把交互式运行时钉为 GUI-scope 的文档，以及 charter §11.6、§18 第 9 条。
- 明确**不**采纳 Prime Agent 的 RLM 单工具与 Continual Harness 自改写；本 ADR 只借鉴其进程拓扑与恢复语义。

## Addendum (Accepted 2026-09-03)

User policy（2026-09-03）：「继续推进下一个阶段，我觉得不需要用 keychains。」

### Credentials

Keychain is **not** a credential path for Agent Session Host (debug or release). Do not enable Keychain readers, do not add Keychain access-group entitlements, and do not call Security.framework for provider API keys in the host or in the GUI publish path. Secrets reach the host only via:

1. a 0600 `DomainCredentialEnvelope` file plus `envelopeID` on `Start`/`SessionSpec` (GUI publishes before start; host redeems, zeros, deletes);
2. already-present process environment when the GUI/CLI spawned the host (inherit; never log).

Release must not reject `credentialEnvelopeId` solely because it is a release build. Missing required secret (GLM / Kimi / custom) fail-closes; never Scripted echo. Frozen proto: no Keychain fields.

### P8 — workspace lease when the GUI is absent

When no GUI holds `DomainWorkspaceAuthorityLease`, `agentry-mcp --backend auto` (the path host-arranged provider MCP already uses) may **fence-claim** that same flock as headless direct: single writer, fail closed on conflict. GUI presence is the existing lease peek (`LOCK_EX|LOCK_NB` then unlock; `mode == "app"`). Do not invent a second lock.

When a GUI-shaped holder exists, auto resolves `.app` (even if the bootstrap socket is down during GUI restart) so tools stay on the proxy and do not steal the GUI flock. GUI re-open uses existing proxy reconnect/replay; no dual-write.

The Rust `agent-host` process is **not** the production workspace writer (`HostConfig.claim_workspace_authority` defaults false). Inventory/search stay in-GUI FFI (ADR-0008; charter §14.2 still: isolate Agent + this lease for tools only).

## Evidence

- 现状：`docs/investigations/architecture-full-flow-2026-09-01.md` §5.4；`AppDelegate.swift:239-268`；`AgentRunMCPToolService.swift:1106-1110`；`AgentModeViewModel.swift:472,3345-3451`；`rust-agent-claude-v1.md:35-37`。
- Charter：`agentry-rewrite-charter.md` §2.2、§6.1、§7.2–7.3、§11.5–11.6、§14.2、§18 第 4/9 条。
- 可复用原语：`Sources/RepoPromptDomainRuntime/DomainAgentRun*.swift`（P12–P18 spec）；`DomainWorkspaceAuthorityLease.swift`（P5-0b）；M5 spec 会话所有权围栏与 interaction settlement；`rust/crates/runtime/src/subscription.rs` cursor/gap/bootstrap；`MCPReplayState.swift` proxy 重放；`DirectHeadlessMCPService.swift` 私有 endpoint 与 launch-token 兑换。
- 参照实现：`PrimeIntellect-ai/prime-agent` @ `0ba0423c`——`packages/coding-agent/docs/daemon.md`、`agent-connection.md`、`src/modes/daemon/daemon-protocol.ts`、`src/core/session-lease.ts`。
- 相关 ADR：ADR-0006（beta soak、fail-closed schema、单写者 lease）、ADR-0008（SLO 先登记的基准 gate；inventory 跨边界往返 50–80× 实测，支撑第 11 条）、ADR-0009（Protobuf 数据面与 `agentry-proto` 权威）。
- Rust 现有权威边界：`rust/crates/runtime/src/agent_claude/`（Claude 进程/NDJSON/turn/control）、`agent_provider.rs` + `provider_json_rpc.rs`（Codex/ACP 进程与 JSON-RPC 相关性，语义仍在 Swift）、`Scripts/headless_runtime_guardrails.sh`。
