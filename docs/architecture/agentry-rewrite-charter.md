> **Snapshot notice (English, added under ADR ruling 14):** This file is a verbatim, version-controlled snapshot of the living design narrative for the Rust-core/SwiftUI-shell rewrite. It is copied here from `docs/designs/rust-core-swiftui-shell-rewrite-2026-08-20.md` (a gitignored, agent-authored working-document directory) specifically so the durable decisions it records have git history. This file is the narrative source; it is not updated in place as a source of truth going forward — the normative, durable rulings extracted from it are ADR-0001 through ADR-0008 in this same directory (`docs/architecture/`). If the working copy under `docs/designs/` continues to evolve, treat divergence between the two as expected — the ADRs, not either narrative copy, are normative for any ruling they cover.

# Agentry 重写设计：Rust 核心 + SwiftUI/AppKit 原生壳（UniFFI 进程内边界）

**Date:** 2026-08-20
**Status:** 战略与语义裁决已全部完成（Gate −1 hard fork、全量终态、Rust-first、Agentry 身份重置、排序/止血/存储 writer/catalog/VCS 等，见 §1 决策与 §18）；UniFFI raw binder 已经 Phase 0 八 gate 验证并由 ADR-0001 Accept（2026-08-20）
**Supersedes:** 本文档早期的 swift-bridge 方案
**Product:** Agentry —— RepoPrompt CE 的正式 hard fork（命名与身份落地见 §13.5）

## 1. 背景与决策摘要

本文回答：如果长期将 RepoPrompt CE 演进为“SwiftUI/AppKit 原生界面 + Rust 领域核心”，应如何划分进程、状态、并发与语言边界，避免把换语言、拆进程和自研同步协议三件高风险工作同时进行。

本仓库是 `repoprompt/repoprompt-ce` 的 GitHub fork。比一切技术选型更前置的问题——与上游的关系——已作为 Gate −1 裁决：**正式 hard fork，上游此后只作为参考借鉴来源**（决策 10、§3.3）。

### 决策

1. **GUI 主干采用单进程、进程内 FFI，不以 RPC/XPC daemon 为默认核心边界。** Rust 以 static library 形式链接进 `Agentry.app`；外部 MCP 通信继续使用独立进程和现有传输拓扑。
2. **UniFFI 0.32.x 是当前首选的 raw binding generator，但仅为 Phase 0 条件选型。** 它必须隐藏在私有生成 target 和手写 Swift façade 后，不能成为 UI 或领域架构。
3. **产品合同采用 command + operation + subscription + versioned event batch。** 不向 Swift 暴露 Rust 领域对象图，也不把 UniFFI async/callback 当作状态同步层。
4. **对已经完成 cutover 的领域，Rust 拥有自己的 runtime、任务、队列、取消和领域权威状态。** 迁移中的未切换领域仍以 Swift 为唯一 mutation authority，禁止双写。Swift `Task.cancel()` 不是业务取消；长任务由调用方预生成 `OperationID`，并支持 cancel-before-admission。
5. **跨边界分为 typed control plane 与 versioned data plane。** 小型 ID、配置、错误和回执使用 UniFFI records/enums；大型文件树、codemap、搜索结果和 transcript 使用项目自有版本化 payload，按批次传输。
6. **Swift 保留 macOS host 能力和 presentation state。** AppKit、Keychain、TCC、security-scoped bookmark、Sparkle、窗口生命周期等不强行下沉；Rust 通过 Host Capability Broker 发请求，禁止直接异步反调 `@MainActor` Swift 对象。
7. **Rust 的“单一事实源”按 authority scope 定义，而不是一个无边界的全局单例。** GUI App 进程通常有一个 process-wide core；每个顶层 headless MCP 进程有一个 direct runtime；窗口和 connection 只有 presentation/subscription/standalone scope，不各自创建 authority。
8. **若 UniFFI 未通过 Phase 0 的绑定技术门槛，则退回手写窄 C ABI。** Phase 0 接受 UniFFI 只代表 raw binder 可用，不批准全部领域迁移；每个领域仍需自己的 cutover gate。
9. **Rust 链路只支持 Apple Silicon。** Cargo 只构建 `aarch64-apple-darwin`；不产出 `x86_64-apple-darwin` archive，不做 lipo，也不维护 Rust 领域的 Intel fallback。已进一步裁决：不等首个 Rust cutover，下一个发布即收敛为 arm64-only，universal/lipo/Rosetta 链路提前退役（§13.2）。
10. **Gate −1 已裁决：与上游 `repoprompt/repoprompt-ce` 正式 hard fork，上游此后只作为参考借鉴来源。** 不以“保持可 merge 上游”约束迁移边界；行为合同与 parity baseline 冻结在 fork point；断供上游功能流（裁决时约 16 commits/天）是被显式接受的代价，消化方式见 §3.3。
11. **终态范围已裁决为全量。** Phase 0–7 全部纳入承诺范围（含 Agent runtime 与 watcher）；各 Phase 的 cutover gate 照常逐一生效，但 Phase 6/7 不再表述为期权。
12. **Rust-first 原则。** 已 cutover 域与新建能力一律以 Rust 侧为主、Swift 侧适配；不为上游数据、旧格式或既有 Swift 表现行为背兼容包袱。不可豁免的硬合同：外部 MCP wire 与工具语义（第三方客户端依赖）、领域正确性语义（edits/路径解析/revision/CAS/恢复）、macOS 平台合同（签名/公证/TCC/生命周期）。表现性行为（排序、估算数字、UI 细节）允许由 Rust 重新定义，但漂移必须知情记录并有新行为测试。
13. **身份重置已裁决。** 更换 bundle identifier、独立 canonical storage 目录、独立 Sparkle feed（新 EdDSA 密钥对）；不导入上游/旧数据，首启即全新状态。与 arm64-only 切换（决策 9）合并为同一个尽早执行的发布动作，先于一切 Rust cutover；产品名已裁决为 **Agentry**（§13.5）。

## 2. 目标与非目标

### 2.1 目标

- macOS UI 保持 SwiftUI/AppKit 原生体验，Rust 领域核心可独立测试和复用。
- 逐域迁移 workspace、codemap、search、edits、Agent、MCP 等核心能力，而不是一次性替换整个应用。
- 保留现有 revision、generation、CAS、atomic snapshot、gap-resync、多窗口和 app/headless/auto 语义。
- 对大仓文件树、tree-sitter、搜索和 Agent 流式输出建立可量化的延迟、吞吐、内存和 MainActor 预算。
- 让 FFI 实现可替换；未来若出现真实隔离或多前端需求，可局部换成 XPC/socket，而不重写领域协议。
- 让 `agentry-mcp` 等 Rust 二进制直接复用普通 Rust crates，不通过 UniFFI 反向调用自身。

### 2.2 非目标

- 不承诺“进程内 FFI = 全链路零拷贝”。UniFFI 对复杂类型会进行 lifting/lowering 和 `RustBuffer` 编解码。
- 不把所有 Swift 状态都搬到 Rust。焦点、展开状态、滚动位置、菜单状态、动画等 presentation state 仍属于 Swift。
- 不在第一阶段创建 launchd daemon、XPC service 或长期驻留后台核心。
- 不直接把 UniFFI generated API 暴露给 View、ViewModel 或 feature target。
- 不使用 Rust→Swift payload callback/async foreign trait 驱动 UI。
- 不为 Rust-enabled 产品构建 x86_64、universal binary 或 Rosetta 兼容路径。
- 不默认用新 crate 替代现有 FSEvents、process group、PTY 等实现而不做行为对齐。
- 不假设 `catch_unwind` 提供进程隔离或能捕获 OOM、abort、stack overflow、SIGSEGV、C/C++ UB。

## 3. 现状与迁移约束

截至本文日期，仓库约有：

| 范围 | 规模（约） | 说明 |
|---|---:|---|
| `Sources/**/*.swift` | 62.3 万行 / 1192 文件 | 包含 App、共享模块与可执行目标 |
| `Sources/RepoPrompt/**/*.swift` | 55.6 万行 / 1018 文件 | 主 App target 源码 |
| `Tests/**/*.swift` | 27.0 万行 / 464 文件 | 主要行为合同 |
| Agent Mode | 13.5 万行 / 243 文件 | 高状态、高并发、外部进程语义复杂 |
| WorkspaceContext infrastructure | 6.5 万行 / 75 文件 | authority、订阅、投影和持久化关键域 |
| `RepoPromptDomainRuntime` | 2.8 万行 / 74 文件 | process/headless scope、CAS、broker 等领域合同 |

这些数字只说明规模，不等价于“可直接迁入 Rust 的行数”。Phase 0 之后仍需按领域做 ownership inventory，不能用“非 View 文件数”推导重写工作量。

### 3.1 术语

- **RuntimeIdentity**：`runtimeID + generation + CoreBuildFingerprint`，用于拒绝旧 runtime 或错误 artifact 的消息。
- **AuthorityScope**：拥有某一领域 mutation、revision 与持久化决定权的范围。
- **PresentationScope**：窗口/标签的 UI 投影视角，不拥有领域 mutation authority。
- **SubscriptionScope**：一次过滤订阅的交付范围；由 `streamID + deliveryCursor` 标识连续性。
- **Authority publication sequence**：领域事实发布顺序，可因订阅过滤而跳号；不能直接当交付 gap 判断依据。
- **Delivery cursor**：单个 subscription 中连续递增的交付游标；gap/resume 以它为准。
- **Workspace catalog revision**：workspace/root catalog 版本，不等于 MCP tool catalog revision。
- **MCP session / Agent session**：前者是 MCP transport/authority scope，后者是 Agent run/turn 的持久业务会话，二者不能混用。

### 3.2 必须保留的现有合同

现有架构中的以下语义必须视为合同，而不是重写时顺手简化：

- `RepoPromptDomainRuntime` 与 `AppDomainRuntimeComposition` 已经表达 staged/partial process-wide domain runtime；当前仍有 app-owned read providers 与 protected mutations，不能提前宣称已是完整单一 authority。
- `WindowStateComposition` 为每个窗口建立 UI/store，但窗口不应各自创建独立核心事实源。
- `DomainWorkspaceModels`、`DomainWorkspaceContextAuthority` 与 `DomainWorkspacePresentationBridge` 已有 runtime ID、sequence、catalog revision、operation ID、atomic subscription、echo suppression 和 gap→snapshot resync 语义。
- `docs/architecture/headless-mcp-runtime.md`、`MCPBackendSelection` 与 `DomainStandaloneScopeCoordinator` 定义了 app/headless/auto 和 connection scope，重写不得退化为“只有 GUI 单例时才工作”。
- `DomainInteractionBroker` 与 `DomainMutationApproval` 已有 deadline、generation、first-completion/FIFO 和取消语义，可作为 Host Capability Broker 的行为模板。
- `FileSystemWatcherIngressMailbox` 与 `FileSystemService+FSEvents` 已有 deep-copy、单调 watermark、FIFO、压力折叠、overflow/rescan 和 flush barrier 语义。
- `NativeAgentRuntimeContracts` 与 `ProcessLauncher` 已有 send/interrupt/shutdown、permission response、`posix_spawnp`、CLOEXEC、signal mask、process group 和 pipe lifecycle 行为。

### 3.3 上游关系：正式 hard fork（Gate −1，已裁决）

本仓库是 `repoprompt/repoprompt-ce` 的 GitHub fork。裁决时（2026-08-20）的上游活动度：近 90 天 1481 个 commit（≈16/天），全部来自上游贡献者；按 90 天内 commit 触达文件次数聚合，上游改动最集中的目录与本文迁移目标高度重叠：

| 目录 | 90 天触达 | 对应迁移阶段 |
|---|---:|---|
| `Sources/RepoPrompt/Infrastructure` | 2779 | Phase 3–5（workspace/MCP/providers） |
| `Sources/RepoPrompt/Features/AgentMode` | 1113 | Phase 6 |
| `Sources/RepoPromptDomainRuntime` | 223 | Phase 4–5 |
| `Sources/RepoPromptMCP` | 146 | Phase 4–5 |
| CodeMap（Features + Core） | 143 | Phase 2 |
| `Sources/CSwiftPCRE2` | 67 | Phase 1 |
| `Sources/RepoPrompt/Features/Search` | 28 | Phase 1–3 |

裁决内容与后果：

1. **正式 hard fork。** 不以“保持上游可 merge”为设计约束，§16 全部 Phase（含上游高频域）解除该约束。代价被显式接受：任一域完成 cutover 后，上游对该域的后续改动永久失去直接合并能力。
2. **Baseline 冻结。** 行为 parity、goldens 与“约 27 万行测试合同”的基准冻结在最后一次全量同步 commit（当前记录：`8136f50d`，2026-08-20 upstream/main→dev 合并；此前为 fork 点 `ae557a59`）。parity 对齐该静态快照，工期与验收以其为准。
3. **同步与借鉴流程（2026-08-20 修订，用户裁决 A）。** 分两个时期：**首个 Rust production cutover 之前**允许周期性整仓同步上游（每次同步为一次显式动作，同步后必须立即执行"同步后身份回归清单"：扩展身份守卫（含上游原始命名空间 `com.pvncher.repoprompt` 全量）、release tooling 测试、合并触及域的 focused 测试；同步带入的旧身份/旧存储路径/架构回归必须在同一批修复后才可提交后续工作）。**首个 production cutover 起**永久停止 merge/rebase，转为只读借鉴：
   - 周期性（建议每月）review 上游 release notes；安全相关修复必须触发评估，功能改动按需评估；
   - 借鉴以“读上游 diff → 在本仓库 canonical authority 一侧重新实现”落地：已 cutover 的域只实现 Rust 版，未 cutover 的域只实现 Swift 版；禁止把上游 Swift 补丁直接贴回已由 Rust 拥有的域；
   - 借鉴改动自带本仓库测试；不回灌上游测试全集，不承诺追平上游 feature roadmap。
4. **产品聚焦。** hard fork 的正当性来自差异化目标（Rust 核心、arm64-only、性能与可维护性），不是复刻上游。断供的功能流不做逐条补齐承诺。
5. **身份与存储隔离（已裁决）。** 更换 bundle identifier、独立 canonical storage 目录与独立 Sparkle feed；不导入上游/旧数据。作为最早的发布动作之一执行（决策 13）；产品名已裁决为 **Agentry**（§13.5）。

### 3.4 底层语义合同（第二轮裁决后）

1. **文本编码与偏移（已裁决方向：全链路 UTF-8）。** Rust 是唯一 decoder：charset 检测与无效字节替换（U+FFFD）政策都在 Rust，产出 canonical UTF-8 文本与字节偏移；Swift 全链路持有同一份 UTF-8 文本与字节偏移，禁止对同一文件建立第二种文本视图（不得用 NSString/Foundation 再解码）。仅 AppKit/Foundation 渲染末梢（NSRange/NSAttributedString/NSTextView）在 snippet 级做 UTF-8→UTF-16 局部转换；NSRegularExpression 等 UTF-16 消费点随正则迁移消失。偏移必须落在 scalar 边界；无效 UTF-8、非 UTF-8 charset、CRLF 与非 BMP 字符进 goldens。前置任务：对现有约 105 处 `utf16` 用法逐个归类（随正则消失 / 渲染末梢转换 / 需改造）。
2. **排序（已裁决：Rust 拥有，算法为确定性自然排序）。** 用户可见排序由 Rust core 定义并交付有序结果，Swift 适配。算法：Unicode simple case-fold + 数字感知（`第2章` < `第10章`）+ 码位 tie-break；零 locale 依赖、零数据表，GUI/headless/CLI 与所有 locale 下顺序完全一致。`localizedStandardCompare` 等 locale 排序不再是行为基线；已知知情漂移：中文文件名不再按拼音序（与 VS Code 等码位系工具一致，Finder 是拼音序孤例）。若未来需要拼音序，在同一排序 API 后替换为 icu4x + 中文 collation 数据，作为有版本标注的可逆行为变更。
3. **正则引擎（已裁决）。** Rust `pcre2` crate + JIT 开启，保留 `com.apple.security.cs.allow-jit` entitlement；性能基线与 SLO 必须标注 JIT 状态；entitlement 集合的任何增删单独过 guardrails 审计。vendored `CSwiftPCRE2` 在该域 cutover 后删除。
4. **Token 估算。** 现实现为启发式估算；按 Rust-first 原则允许在 Rust 侧重新定义（数字允许漂移）。若升级为真实 tokenizer，作为独立、可归因的变更，不与语言迁移混在同一 cutover。

## 4. 先例与使用边界

| 先例 | 可借鉴之处 | 不应过度推导 |
|---|---|---|
| Mozilla UniFFI / Application Services | Rust 核心、多语言 bindings、Arc object、错误与 ABI checksum 的长期实践 | 不证明 UniFFI 的 Swift async、取消和热数据路径适合本项目 |
| 1Password Rust core | 共享 Rust 业务核心和生成绑定的组织方式 | 不是“RepoPrompt macOS SwiftUI 架构已被一比一验证”的证据 |
| Zed | Rust 可承载索引、解析、搜索和高并发状态 | Zed 的 UI/runtime 模型与 SwiftUI/AppKit 不同 |
| Xcode / SourceKit | 易崩或不可信编译器组件值得进程隔离 | 不能由此推出整个 Rust core 都应成为 daemon |

架构决策以 RepoPrompt 的行为、性能、发布和恢复实验为准，先例只用于提出候选方案。

## 5. 方案比较与决策

### 5.1 候选

- **A. UniFFI 进程内 FFI**：当前候选；通过 Phase 0 后接受。
- **B. swift-bridge 进程内 FFI**：不再作为默认选择。
- **C. 手写窄 C ABI**：UniFFI 不达标时的回退方案；也可在实测需要时承载唯一的 immutable blob fast path。
- **D. XPC/RPC daemon**：只在 §14 的触发条件成立时局部采用。

### 5.2 决策矩阵

| 维度 | A UniFFI | B swift-bridge | C 手写 C ABI | D XPC/RPC |
|---|---|---|---|---|
| 绑定成熟度/维护压力 | 高 | 中低 | 完全由项目承担 | 传输与 schema 由项目承担 |
| Record/enum/error/object | 完整 | 中等 | 全部手写 | 取决于 wire schema |
| Swift 6 基础接口 | 可行，但 async 仍为 partial | 风险更高 | 可完全控制 | Swift 侧可控 |
| 结构化取消 | 必须显式设计 | 必须显式设计 | 可完全控制 | 必须显式设计 |
| 大型结构数据 | 有序列化/复制 | 可更接近少拷贝 | 可定制 | 必然编码、拷贝和 IPC |
| MainActor 反调 | foreign trait 有隔离风险 | extern Swift 有重入风险 | 可设计但仍危险 | 消息天然隔离 |
| 崩溃隔离 | 无 | 无 | 无 | 有 |
| macOS 权限/生命周期 | 单进程，简单 | 单进程，简单 | 单进程，简单 | helper/daemon 更复杂 |
| 多前端/headless | API 消息化后可演进 | 同左 | 同左 | 天然支持 |

### 5.3 决策

采用 **A 作为条件候选**，理由是 UniFFI 的生产成熟度、类型模型、Arc object、错误转换、API checksum 和跨平台期权优于 swift-bridge。选择它不是因为性能更高，也不意味着采用其所有高级功能。

以下 UniFFI 能力默认禁止进入产品主干，除非单独 ADR 和实证批准：

- async foreign trait / callback interface；
- payload callback；
- 把生成对象当领域对象图使用；
- 把 UniFFI 内部序列化格式用于持久化、journal 或 RPC；
- 依赖 UniFFI 自动传播 Swift Task cancellation；
- 由 UniFFI 决定 Tokio runtime 生命周期。

## 6. 目标架构

```text
┌──────────────────────────────────────────────────────────────┐
│ Agentry.app（单进程）                                      │
│                                                              │
│ SwiftUI/AppKit Views                                          │
│        │ intents                                  ▲ projection│
│        ▼                                          │ updates   │
│ @MainActor Presentation Stores                               │
│        │                                          ▲           │
│        ▼                                          │           │
│ AgentryCoreBridge（手写 Swift actor/façade）                │
│        │ command/cancel/response        batch drain│           │
│        ▼                                          │           │
│ AgentryUniFFIRaw（私有生成 target；UI 不可直接 import）      │
│ ═══════════════ C ABI / UniFFI generated bindings ═══════════ │
│        │                                          ▲           │
│        ▼                                          │           │
│ agentry-ffi（唯一依赖 UniFFI 的 Rust crate）                        │
│        │                                          ▲           │
│        ▼                                          │           │
│ agentry-runtime（自有 Tokio runtime、task registry、有界队列）       │
│        │                                                      │
│ agentry-domain-workspace / codemap / search / edits / agent / mcp  │
└──────────────────────────────────────────────────────────────┘
           ▲
           │ 现有 app transport / external protocol
┌──────────┴────────────┐
│ agentry-mcp（Rust） │ app 模式走现有传输；headless 直接调用 crates
└───────────────────────┘
```

### 6.1 设计铁律

1. **生成层是私有实现细节。** 只有 `AgentryCoreBridge` 可以 import raw bindings。
2. **领域 crates 不依赖 UniFFI。** 所有 annotation、DTO mapping 和 FFI glue 收敛在 `agentry-ffi`。
3. **持久身份使用显式 ID/revision/generation。** 不能用 UniFFI object handle 代替 workspace、window、run 或 operation 身份。
4. **事实源按 authority scope 定义。** GUI process core、顶层 headless process direct runtime 和测试 runtime 各自拥有清晰的 RuntimeIdentity 与生命周期；connection/window 不各建 authority。
5. **订阅从原子 bootstrap 开始。** snapshot 与 cursor 必须在同一原子操作取得，消除“先拉快照再订阅”的竞态。
6. **每条队列同时有 count 和 byte 上限。** 没有无界 `AsyncStream`、无界 channel 或逐 token 跨 FFI。
7. **所有长操作均可显式取消和关闭。** Swift 对象 `deinit` 只能作为兜底，不能承担产品生命周期。

## 7. Authority、窗口与运行拓扑

### 7.1 GUI App

- 每个 App process 创建一个 `CoreRuntime` RuntimeIdentity。
- core 可管理多个 workspace/root/session，不为每个窗口复制领域状态。
- 每个窗口创建独立 `PresentationScope` 与 subscription，保存窗口 ID、可见 workspace、delivery cursor 和 UI 本地状态。
- Swift store 可以拥有 presentation state；只有已经 cutover 的领域 mutation 才进入 Rust authority，未切换领域仍由 Swift 唯一写入。
- 事件携带 RuntimeIdentity、authority scope、stream ID、publication sequence、delivery cursor、workspace catalog revision 和 origin operation ID，支持 own-window echo suppression 与跨窗口更新。

### 7.2 app/headless/auto

- `agentry-mcp` 的 app 模式继续通过现有外部 transport 访问 GUI authority，并保留 proxy reconnect/replay 语义。
- headless 模式为每个顶层 MCP 进程创建一个 direct runtime generation；该进程内的 standalone connection scope、run scope 和 child connection 共享它，不绕 UniFFI。
- auto 模式在 initialize 前执行一次有界 probe，然后将后端固定到整个 MCP 进程生命周期；默认仍偏向 app，interactive/exec 等 app-only 能力不能静默落入 headless。
- GUI 与 headless 共享 domain crates 和 project-owned protocol schema，不共享进程内 handle。

### 7.3 Canonical storage 与跨进程 writer

App 与 headless 可能访问同一 canonical storage root。已裁决采用**单 writer lease**：任一时刻只有一个 runtime 持有某 canonical storage 的 mutation 权；GUI 活跃时 headless 进程对该存储 proxy 到 GUI authority 或对 mutation fail closed。lease 的获取、续期、失效检测与陈旧 lease 抢占语义在 Phase 4 实现并验证。

备选方案（跨进程 file lock + durable CAS + external reload，或显式 fail closed）仅在 lease 方案被 Phase 4 实证证伪时启用。

禁止两个独立 in-memory authority 在没有 lease/lock/CAS/reload 的情况下同时写同一 journal/storage。lease 的实现与验证是 Phase 4 的阻断 gate，不是可以推迟到上线后的优化。

## 8. UniFFI 边界设计

### 8.1 crate 与生成方式

采用 proc-macro-only 的独立 `agentry-ffi` crate：

```text
agentry-domain-*    不依赖 UniFFI
agentry-runtime     不依赖 UniFFI
agentry-proto       项目自有稳定 payload schema
agentry-ffi         DTO/handle/mapping + UniFFI annotations
```

不再维护一份平行 UDL。Rust 签名是 raw bindings 的单一来源，但**业务协议**仍由 `agentry-proto` 的显式 version/schema 定义。

### 8.2 推荐 raw API 形态

以下为方向性伪代码，不是承诺的最终生成签名：

```rust
#[derive(uniffi::Object)]
pub struct CoreRuntime { /* Arc + internal runtime */ }

#[uniffi::export]
impl CoreRuntime {
    #[uniffi::constructor]
    pub fn new(config: CoreConfig) -> Result<Arc<Self>, CoreError>;

    pub fn initialize(&self) -> Result<CoreHandshake, CoreError>;

    // command 内含调用方预生成的 typed OperationId 与 request fingerprint。
    // 同步 Err 只表示配置/FFI/admission 失败；接纳后的业务结果走 terminal event。
    pub fn execute(
        &self,
        command: CommandEnvelope,
    ) -> Result<AdmissionReceipt, CoreError>;

    pub fn cancel_operation(
        &self,
        identity: RuntimeIdentity,
        operation_id: OperationId,
    ) -> Result<CancelReceipt, CoreError>;

    pub fn open_subscription(
        &self,
        scope: SubscriptionScope,
    ) -> Result<SubscriptionBootstrap, CoreError>;

    pub fn try_drain(
        &self,
        subscription_id: SubscriptionId,
        max_events: u32,
        max_bytes: u64,
    ) -> Result<DrainBatch, CoreError>;

    pub fn respond_host_request(
        &self,
        response: HostResponse,
    ) -> Result<(), CoreError>;

    pub fn close_subscription(&self, subscription_id: SubscriptionId) -> Result<(), CoreError>;
    pub fn begin_shutdown(&self, identity: RuntimeIdentity) -> Result<ShutdownReceipt, CoreError>;
}
```

默认优先同步、快速、只做入队/取批次的 FFI 方法。计算、I/O 和进程工作在 `agentry-runtime` 内执行。少量 Rust async → Swift `await` 方法只有通过真实接口的 Swift 6、取消和泄漏测试后才能加入。

### 8.3 少量 object、显式 close

UniFFI object 在 Rust 侧由 `Arc<T>` 支撑。只允许少量根对象，例如：

- `CoreRuntime`
- 必要时的 `SubscriptionHandle` 或 `OperationHandle`

默认优先使用显式 ID，避免 Swift proxy 生命周期决定 Rust 业务生命周期。`close`/`shutdown` 必须幂等，并验证重复关闭、并发关闭和 Core RuntimeIdentity 变化。

### 8.4 Swift façade

`AgentryCoreBridge` 负责：

- 隐藏 generated records、objects 和 internal errors；
- 将 raw error 映射为 App 稳定错误模型和本地化信息；
- 在创建 Swift Task 前预生成 typed `OperationID` 并写入 command；用 `withTaskCancellationHandler` 把 Swift cancellation 映射为可先于 admission 到达的幂等 `cancelOperation`；
- 管理 subscription/wake source/close；
- 后台解码 payload，并只在 MainActor 应用投影；
- 在 RuntimeIdentity 变化后拒绝旧 receipt、event 和 host response；
- 对 UI 提供项目自己的 `AsyncSequence` 或 store API，而不是转发 UniFFI async。

raw generated object 即使声明 `@unchecked Sendable`，也不能因此被视为已通过项目并发审计。

## 9. Runtime、事件、取消与背压

### 9.1 Rust 自有 runtime

- `agentry-runtime` 创建、配置并关闭自己的 Tokio runtime。
- UniFFI 的 async compatibility helper 不拥有产品 runtime，也不决定线程数、shutdown deadline 或 task supervision。
- runtime 保存 operation/task registry；每个任务有 caller-generated operation ID、request fingerprint、scope、deadline、RuntimeIdentity 和 terminal state。
- 支持 cancel-before-admission tombstone、重复 cancel 和 request fingerprint collision 检测；完成、取消、超时、shutdown 遵守 first-terminal-wins，迟到结果只记诊断。
- cancel、shutdown、approval/terminal response 使用预留容量或独立 control lane，不能被普通 command/progress 队列饱和阻断。
- `beginShutdown` 只发起关闭并快速返回；等待 task join/超时通过 terminal completion 观察，不能在 Swift actor 上同步长时间阻塞。

### 9.2 取消

UniFFI 0.32 不会把 Swift `Task.cancel()` 自动传播给 Rust Future。所有长操作必须提供显式取消：

```text
operationID = caller.generate()
execute(CommandEnvelope(operationID, fingerprint, payload)) -> AdmissionReceipt
cancelOperation(RuntimeIdentity, operationID) -> CancelReceipt
```

取消可以先于 command admission 到达：Rust 为短时间窗记录 tombstone，之后到达的同 operation/fingerprint 不得启动；同 ID 不同 fingerprint 必须作为 collision 拒绝。Swift façade 的 cancellation handler 只负责发送取消意图；Rust 仍需在安全点检查 token、终止子进程/解析任务并发布唯一 terminal event。

Agent 的 `interruptRun`、permission response 和 `shutdown` 保留独立领域语义，不能全部简化成取消一个 Swift Task。

### 9.3 Subscription bootstrap

```text
openSubscription(scope)
  -> subscriptionID + streamID
  -> RuntimeIdentity
  -> atomic initial snapshot
  -> nextDeliveryCursor
```

snapshot 与 next delivery cursor 必须来自同一 authority 临界区。每个事件可以同时记录 authority publication sequence（用于事实排序/诊断）和连续的 per-subscription delivery cursor。过滤掉的 publication 不构成交付 gap；Swift 只用 stream ID + delivery cursor 判断 gap/resume。发现 delivery gap、RuntimeIdentity mismatch、decode failure 或 queue overflow 后，丢弃局部投影并请求新的 atomic bootstrap。

### 9.4 有界批量 drain

事件不按节点、token 或字节逐个跨 FFI。每个 subscription 维护：

- `maxQueuedEvents`
- `maxQueuedBytes`
- coalescing policy
- overflow/gap marker
- priority/class（例如 approval/terminal/cancel 不得丢失，progress/invalidation 可 coalesce）
- 为 overflow marker 和 terminal/control event 预留的队列外状态或容量

command ingress、host response 和 subscription outbound 都必须有独立 count/byte 上限与 overload 语义。`tryDrain(maxEvents:maxBytes:)` 返回有限批次以及 `hasMore`；Swift 持续 drain 到 empty。单个 event 超过 `maxBytes` 时必须返回明确 oversize/resnapshot 结果，不能形成永远取不出的 livelock。UI 大数据通过分页/窗口化 snapshot API 获取，事件只携带足够的增量或 invalidation 信息。

### 9.5 唤醒机制

首选 macOS 实现：

- Rust 为 core 暴露一个 nonblocking wake read FD 的受控副本；
- armed 队列从 empty→non-empty 时向 write end 写入/合并一个信号；
- Swift 用 `DispatchSourceRead` 监听，切到 bridge actor 后循环 `tryDrain`，直到 `hasMore == false`；
- 消费者在队列锁内执行 rearm-and-recheck：若 rearm 时已有新数据则继续 drain，否则重新 armed，避免 producer 恰好落在“最后一次 drain 与 rearm”之间造成 missed wake；
- 明确定义 FD dup/owner/close、EAGAIN、cancel handler、core shutdown 和 RuntimeIdentity 更换。

这避免 Rust 同步反调 Swift、MainActor conformance 冲突和 callback 重入。若 FD 方案未通过 Phase 0，可比较“无 payload wake callback”或显式 async pull，但仍禁止 payload callback。

## 10. Control plane 与 Data plane

### 10.1 Typed control plane

适合用 UniFFI records/enums/errors 的内容：

- runtime/workspace/window/subscription/operation ID；
- scope、revision、generation、cursor；
- 小型配置、命令回执、状态枚举；
- domain error category；
- batch metadata。

这些类型的价值是边界可读、生成一致和编译期检查，不是零拷贝。

### 10.2 Versioned data plane

以下数据默认使用 `Data`/`Vec<u8>` 中的项目自有 envelope：

- 大型文件树 snapshot/delta；
- codemap 与语法分析结果；
- 搜索结果批次；
- Agent transcript/output；
- MCP JSON 或其他运行时大 payload。

运行时 FFI transport、durable journal/export 和 external MCP wire 必须拥有独立的 envelope/version/compatibility policy；它们可以复用 payload types，但不能共享一套未经区分的兼容承诺。运行时 event envelope 至少包含：

```text
schemaVersion
payloadKind
RuntimeIdentity
scope + streamID
firstDeliveryCursor / lastDeliveryCursor
authorityPublicationSequence（适用时）
workspaceCatalogRevision（适用时）
compression/encoding 标识
payload checksum（需要时）
```

外层 batch metadata 是 runtime identity、stream 和 cursor 的唯一权威；内层 payload 不重复声明冲突字段。所有 decoder 必须设置最大 decoded size、最大集合/字符串长度、压缩比上限，未知 schema/version fail closed，并接受 malformed/fuzz 输入。UniFFI 的内部 `RustBuffer` 格式只用于 bindings lifting/lowering，不是稳定 wire format。

### 10.3 拷贝与 fast path

UniFFI 0.32 对同步 Swift `Data` → Rust `&[u8]` 可在调用期间借用；它不适用于跨 await、保存 buffer 或 Rust→Swift 通用零拷贝。大 payload 必须用统一 harness 记录 wall/CPU、Instruments allocations、malloc bytes、峰值 RSS、decode/apply signpost；无法直接观测的“copy 次数”不能凭实现猜测。先冻结当前 Swift fixture/baseline，再在查看 Rust candidate 结果前登记绝对 SLO 和允许回退。

只有真实 benchmark 未达预算时，才允许增加一个审计过的 immutable owned-buffer C ABI fast path，并满足：

- 仍隐藏在 `AgentryCoreBridge` 后；
- 明确 allocator、owner、length、alignment 和 free function；
- 不建立第二套 command/event 语义；
- ASan、随机 close、double-free 和 leak soak 全部通过。

## 11. Host Capability Broker 与 macOS 边界

### 11.1 不使用 foreign trait 直接反调平台对象

Rust 需要平台能力时发布 `HostRequest`：

```text
requestID
RuntimeIdentity
scope/windowID
kind
deadline
payload
```

Swift bridge claim request，在正确 actor 上执行，再调用 `respondHostRequest`：

```text
requestID
RuntimeIdentity
result/error
```

Broker 必须支持 monotonic deadline、cancel、first-completion-wins、exactly-once claim、窗口消失时的明确 reroute/fail policy、App shutdown 和迟到 response 丢弃。每类 capability 有 allowlist、scope/path fencing 和审计字段；security-scoped resource access lease 必须覆盖 Rust 实际 I/O 生命周期，不能在文件面板返回后提前释放。

### 11.2 明确保留 Swift 的能力

- SwiftUI/AppKit View、交互、动画、菜单、快捷键、文本系统；
- Keychain 与安全存储；
- NSOpenPanel、TCC、security-scoped bookmark；
- Sparkle；
- NSWorkspace、Dock、通知和窗口生命周期；
- presentation/navigation/focus/scroll state。

### 11.3 FSEvents

初期继续使用现有 Swift/CoreServices adapter。CoreServices callback 内只做 deep-copy 与 mailbox accept/watermark，不能阻塞或直接跨 FFI；唯一 mailbox drain worker 按 event ID/flags/watermark 批处理后同步 ingest 到 Rust。必须保留：

- 单调 watermark；
- overflow/root rescan；
- pressure collapse；
- flush/freshness barrier；
- root replacement 与 stale event 拒绝。

只有证明 Rust watcher 能完整对齐这些语义并改善维护或性能，才在后续阶段下沉；“有 `notify` crate”不是迁移依据。

### 11.4 Agent 子进程

目标上 Agent state machine 可进入 Rust，但 provider/process launcher 必须逐个迁移。`portable-pty`、`tokio::process` 不能被假设与现有 `posix_spawnp`、process group、signal、CLOEXEC、pipe shutdown 和权限行为等价。

### 11.5 调度、能耗与 App Nap

Swift Concurrency 自带 QoS 传播与优先级反转避免；Tokio 没有 QoS 概念。核心迁入自有 runtime 后必须补齐调度公民性：

- Tokio worker/blocking 线程在启动 hook 中设置显式 pthread QoS（交互路径 `userInitiated`、后台索引 `utility`），不得全部落在默认优先级；
- UI 正在等待的操作与纯后台工作使用不同的 QoS/队列策略，避免交互路径被后台索引饿死；
- runtime 空闲时必须 quiesce：无活跃 operation/subscription 时不允许周期性 timer 唤醒进程，不阻止 App Nap；
- 长时后台工作沿用现有 `ProcessInfo.beginActivity` 模式，由 Swift host 按 operation 生命周期持有/释放（现有 `ServerController` 的 power activity 是模板）；
- cutover gate 增加能耗观测项：空闲零唤醒、`powermetrics`/Activity Monitor 无异常定时器。

### 11.6 退出与系统生命周期序列

`beginShutdown` 必须接入宿主生命周期：

- `applicationShouldTerminate` → 延迟回复 → core drain（带 deadline）→ Agent 子进程 interrupt/reap → 持久化 flush → 回复 terminate；超时记录并强制退出，不允许无限等待 Rust task；
- sudden termination：存在未落盘 mutation 或活跃 Agent run 时禁用，空闲时恢复；
- 系统睡眠/唤醒：watcher 唤醒后走 overflow/rescan 路径重建一致性；Agent 子进程跨睡眠语义按 provider 单独声明；
- 窗口全关但进程存活（MCP background 模式）时，core 与 subscription 的保留/降级策略显式定义。

### 11.7 可观测性与诊断桥

现有观测（Sentry Cocoa、breadcrumb/trace span、`Features/Diagnostics` perf 诊断与 `app_settings` 开关）全部在 Swift 侧；域迁入 Rust 后不允许观测断层：

- Rust panic guard 捕获的 panic 携带 Rust backtrace 经 Swift 侧上报 Sentry（复用现有 enable/disable 与隐私开关），单通道，不引入 sentry-rust 第二 SDK；不可恢复崩溃依赖现有 native crash 采集 + dSYM 中的 Rust 符号；
- `agentry-runtime` 内建 `tracing`，桥接到 os_log/os_signpost（Instruments 可见）与现有诊断文件通道，signpost 命名沿用现有领域前缀；
- 每域 cutover 必须列出现有诊断能力清单并给出 Rust 对等物（§15.3 观测 parity gate）；
- DEBUG 专用诊断继续经 `app_settings` 键开关，Rust 侧经 command/config 下发，不另造开关体系。

## 12. Rust workspace、Swift targets 与文件布局

### 12.1 逻辑模块摘要

先用简洁的逻辑分层表达目标，避免目录树掩盖真正的依赖方向：

```text
Rust:
  agentry-domain-workspace  # workspace/index/search/selection/edit/VCS 领域
  agentry-domain-codemap    # tree-sitter、artifact/CAS
  agentry-domain-agent      # Agent state machine、provider contracts
  agentry-runtime           # Tokio、task registry、event queues、host broker
  agentry-proto             # 项目自有 versioned payload schema
  agentry-ffi               # 唯一依赖 UniFFI 的 crate

Swift:
  AgentryUniFFIRaw  # generated；外部不可见
  AgentryCoreBridge # 手写 Swift 6 actor/façade
  RepoPromptApp        # 现有 App target；SwiftUI/AppKit 与 presentation
```

依赖只允许向下：

```text
RepoPromptApp
  -> AgentryCoreBridge
    -> AgentryUniFFIRaw
      -> CAgentryRustCore
        -> libagentry_ffi.a
```

`CAgentryRustCore` 是 SwiftPM 所需的极薄 Clang/link target，不是第四层 Swift 业务 API。SwiftPM 当前不能在同一个 target 中混放 Swift 与 C-family sources，因此不能把 UniFFI 生成的 Swift、C header 和 module map 全塞进 `AgentryUniFFIRaw`。

### 12.2 建议的真实仓库路径

```text
rust/
  Cargo.toml                 # virtual workspace manifest
  Cargo.lock                 # workspace 唯一 lockfile
  rust-toolchain.toml        # 固定 Rust toolchain
  .cargo/
    config.toml              # 只声明 aarch64-apple-darwin 相关配置
  crates/
    domain/
      workspace/             # package: agentry-domain-workspace
      codemap/               # package: agentry-domain-codemap
      agent/                 # package: agentry-domain-agent
    runtime/                 # package: agentry-runtime
    proto/                   # package: agentry-proto
    ffi/                     # package: agentry-ffi
  bins/
    agentry-mcp/          # package/binary: agentry-mcp
  tools/
    xtask/                   # codegen、arm64 archive、header 校验

Sources/
  CAgentryRustCore/       # Clang/link target；没有业务逻辑
    shim.c
    include/
      AgentryCoreFFI.h    # generated
      module.modulemap       # generated/normalized
  AgentryUniFFIRaw/
    Generated/
      AgentryCore.swift   # generated；禁止手改
  AgentryCoreBridge/
    CoreBridge.swift         # public façade
    CoreOperations.swift
    CoreSubscriptions.swift
    CoreHostBroker.swift
  RepoPrompt/                # 现有路径；SwiftPM target 名仍是 RepoPromptApp
```

Cargo workspace 使用 virtual manifest，并按职责做一层语义分组：`crates/domain/*` 是领域 package，`crates/{runtime,proto,ffi}` 是跨领域基础边界，`bins/*` 是最终可执行产品，`tools/*` 是仓库工具。所有成员仍共享一个 `Cargo.lock`、`target` 与 workspace lint/profile。

目录名不承担 Cargo package identity。叶子目录保持短名 `workspace/`、`codemap/`、`agent/`，各自 `Cargo.toml` 中的 package 名仍为 `agentry-domain-workspace`、`agentry-domain-codemap`、`agentry-domain-agent`。这样文件路径可读，`cargo -p`、编译日志和依赖图中的名称也不会失去项目与分层前缀。根 manifest 显式列出：

```toml
[workspace]
members = [
    "crates/domain/*",
    "crates/runtime",
    "crates/proto",
    "crates/ffi",
    "bins/*",
    "tools/*",
]
```

初始只建立三个有明确领域边界的 `agentry-domain-*` crate。search、edits、VCS、MCP tool semantics 先作为相应领域或 binary 内部 module；只有满足“可独立测试/复用、依赖方向稳定、feature 或编译成本需要隔离”中的至少一项时，才提取为新 crate。避免在迁移开始前按每个名词制造大量微型 crate。

关键约束不变：`agentry-domain-*` 不依赖 UniFFI、Swift/AppKit 或 GUI transport；只有 `agentry-ffi` 含 UniFFI annotation 和 DTO mapping；`RepoPromptApp` 永远不能直接 import `AgentryUniFFIRaw`。

### 12.3 社区惯例与本项目取舍

- **Rust 为辅的多语言仓库**常把 virtual Cargo workspace 放在 `rust/`，而不是让根 `Cargo.toml` 与现有 SwiftPM 根争夺“主构建入口”；UniFFI Starter 采用这一布局。Rust 主导的 Mozilla Application Services 则把 Cargo workspace 放仓库根并按 component/support 语义分组。RepoPrompt 当前是 SwiftPM macOS App，因此选择 `rust/`，并在其内部使用 `domain`/`bins`/`tools` 分组。
- **generated bindings 与手写 API 分层**是常见做法：底层 target 只负责 C ABI/生成 Swift，上层再提供符合 Swift 命名、actor isolation 和生命周期习惯的 wrapper。RepoPrompt 进一步禁止 App 直接依赖 generated target。
- **XCFramework 是分发格式，不是架构边界。** Matrix Rust SDK、Automerge Swift 等跨平台/公开 SDK 使用 XCFramework 很合理；本项目是同仓、单平台、单架构 App，先直接链接 `.a` 更少一层生成和缓存失效。若 SwiftPM 实测迫使使用 XCFramework，再使用 arm64 单 slice 容器。
- **`xtask` 适合固化多步原生构建**，但它仍由 conductor 调度；不能让 `cargo xtask` 成为绕开现有 build/release lane 的第二套入口。

## 13. 构建、代码生成与发布

### 13.1 版本和生成物

- 精确锁定 `uniffi`、scaffolding 和 `uniffi-bindgen-swift` 为同一版本；首个候选为 `=0.32.0`。
- 锁定 Rust toolchain 与 `Cargo.lock`。
- generated Swift/header/modulemap 纳入版本控制，以便 review；CI 在 clean environment 重新生成并要求零 diff。
- 提交生成源码不代表无需 Rust toolchain：本地/CI 构建仍需匹配的 arm64 Rust archive；若未来改用单 slice XCFramework，它也必须由同一受控 artifact pipeline 生成。
- 初始化同时校验两层身份：UniFFI API checksum 只检测 bindings/ABI contract；项目自有 `CoreBuildFingerprint` 还必须覆盖 ABI epoch、payload schema set、Rust source revision、Cargo.lock digest、toolchain、feature set 与 build profile，用于发现“同 API、错误实现版本”的 archive。

### 13.2 arm64-only 构建链路

Rust-enabled 产品只支持 Apple Silicon。权威流程为：

1. conductor 设置受控的 `CARGO_TARGET_DIR`，执行 `cargo build --manifest-path rust/Cargo.toml --target aarch64-apple-darwin -p agentry-ffi -p agentry-mcp`；
2. 从同一 `libagentry_ffi.a` 生成/校验 UniFFI Swift source、C header 与 module map；
3. `CAgentryRustCore` 链接该 arm64 static archive，`AgentryUniFFIRaw` 编译生成 Swift，`AgentryCoreBridge` 提供手写 API；
4. 构建 arm64 Swift `Agentry` product，并暂存 Cargo 产出的 arm64 `agentry-mcp` binary；
5. 生成 dSYM 并验证 Rust frame symbolication；
6. 继续现有 codesign、notarization、Sparkle 和 artifact 检查，但移除 x86_64、lipo 和 Rosetta 步骤。

同仓开发和 App 打包默认直接链接单个 `.a`，不为只有一个 macOS/arm64 slice 的内部组件预先引入 XCFramework。XCFramework 更适合跨平台/多 slice 分发；若 Phase 0 证明 SwiftPM 或生成 Xcode workspace 无法稳定直接链接 archive，可退回**单 slice XCFramework**，但它只是包装容器，不得重新引入 x86_64 构建。

已裁决提前切换：不等首个 Rust cutover，下一个发布即收敛为 arm64-only；x86_64 构建、lipo 与 Rosetta 验证链路同步退役（`build_swiftpm_release_products.sh`、`validate_app_architectures.sh`、`compare_swiftpm_release_resources.py` 等改为断言 arm64-only）。该切换与身份重置发布（决策 13：新 bundle identifier/存储目录/Sparkle feed）合并为同一个发布动作，从源头避免“arm64 使用 Rust authority、x86_64 继续写旧 Swift authority”的双实现问题。

所有 Cargo/Swift 构建必须接入 conductor 的 build/release lane，不能创建旁路编译入口。Phase 0 必须在仓库内加入可复现的 direct-staticlib/SwiftPM integration spike，验证 clean build、generated workspace、普通 module map、incremental rebuild 和缺失/stale archive 的 fail-fast 行为。

### 13.3 Swift 6

- raw generated target 必须用实际 RepoPrompt 工具链做 Swift 6 strict-concurrency 和 warnings-as-errors typecheck。
- 不使用 `@preconcurrency import`、全局 Swift 5 target 或大范围 `@unchecked Sendable` 封装来隐藏生成问题。
- generated code 自带的 `@unchecked Sendable`/`nonisolated(unsafe)` 视为需要 façade 隔离和测试的 unsafe surface。

### 13.4 供应链、预检与工程接入

当前 Makefile/Scripts/conductor 对 cargo 零感知；Rust 进入构建图时同步落地：

- **conductor**：cargo 构建作为 daemon job 接入，claim `build` lane 并占用 heavy slot；`CARGO_TARGET_DIR` 由 conductor 控制并纳入缓存；新增 `dev-cargo-*` 别名进入 CLAUDE.md 验证矩阵。
- **预检与守卫**：`rpce-contribution-check` 扩展到 `rust/`（staged/outgoing secret 扫描覆盖 `Cargo.lock` 与 vendored 内容）；参照 `codex_vendor_guardrails.sh` 模式建立 Rust 工具链/依赖守卫（toolchain 固定、依赖清单、entitlement 不漂移）。
- **供应链**：CI 强制 `cargo deny`（license/advisory/ban）与 `cargo audit`；发布物聚合 Rust 依赖 license/NOTICE；不引入 cargo-vet（当前维护规模下成本不值）。
- **开发体验**：生成 Xcode workspace 只呈现 prebuilt archive 与 generated Swift target，Rust 开发走 rust-analyzer；`docs/architecture/source-layout.md` 增补 `rust/` 所有权规则。
- **持续性能防线**：cutover 后该域 SLO fixture 进 nightly 基准 CI，防止 cutover 时刻之后的静默回归。
- **文档治理（已裁决：入库）**：本文件的决策提升为 `docs/architecture/` 下的 ADR 序列并纳入版本控制（`docs/designs/` 目前被 gitignore，不能承载长期章程）；本文件保留为叙事总览，§18 各已裁决条目对应独立 ADR。

### 13.5 身份重置发布（Milestone 0：Agentry）

产品名已裁决：**Agentry**。本发布是整个计划的第一个可执行里程碑，不依赖任何 Rust 工作，与 arm64-only 退役（§13.2）合并为同一个发布动作。

用户可见身份（本发布必须完成）：

- App 与可执行名：`RepoPrompt.app` → `Agentry.app`；`CFBundleName`/`CFBundleDisplayName`/`CFBundleExecutable` 与 SwiftPM app product 名同步更换。
- Bundle identifier：启用全新标识（建议 `io.github.z23cc.agentry` 或自有域名反写；打包模板的 `__BUNDLE_ID__` 注入点已存在）。
- Canonical storage：`~/Library/Application Support/Agentry/`；不读取、不迁移旧 `RepoPrompt CE` 目录（决策 13：首启全新状态）。
- Sparkle：新 appcast feed URL + 新生成的 EdDSA 密钥对（`SUFeedURL`/`SUPublicEDKey`）；同时建立 stable 与 beta 两条 channel（止血机制已裁决为 beta 浸泡 + 只向前修，beta channel 即其载体，§15.3 第 10 条）。
- 遥测：新 Sentry 项目与 DSN；Info.plist 遥测键随产品名更换。
- CLI 与 MCP 服务名：`rpce-cli-debug` → `agentry-cli-debug`（含安装链路、`doctor.sh` 与 Settings 安装入口）；MCP 二进制 `repoprompt-mcp` → `agentry-mcp`，对外 MCP server 展示名同步。
- 发布架构：本发布即 arm64-only（§13.2）。

开发者侧跟进（同批或紧随其后）：

- `package_app.sh`、`doctor.sh`、conductor 的 app/bundle/DebugApps 路径与进程识别更新；
- CLAUDE.md、README 与 docs/architecture 的名称、命令与验证矩阵更新；
- 签名身份/TeamIdentifier 不变；entitlement 集不因改名增删（§3.4 第 3 条）。

显式非目标：

- 不重命名现有 Swift module/target/内部标识（`RepoPrompt*` 内部名可长期保留或机会性重构）；新建的 Rust crates（`agentry-*`）与 bridge targets（`AgentryUniFFIRaw`/`AgentryCoreBridge`/`CAgentryRustCore`）从出生即用 Agentry 命名；
- 不迁移旧数据，不提供旧 feed → 新 feed 的自动搬家（hard fork + 全新身份，用户手动安装一次）。

同名风险备注：SAP 历史上有企业移动平台组件 “Agentry”（SAP Mobile Platform 遗留产品线）；本项目为开源 macOS 工具，领域冲突风险低，但 bundle id/域名注册避开 SAP 相关命名空间。

## 14. 错误、panic、恢复与何时拆进程

### 14.1 Error 与 panic

- 所有可能发生业务错误或 panic 的 exported product API 都返回 `Result`；非 throwing export 只允许不可失败的 trivial 操作。
- domain error 映射成稳定 category/code/context；本地化文本由 Swift presentation 层生成。
- UniFFI scaffolding 会把可 unwind panic 转成 internal call status，但不会自动 poison 对应 core。每个 export 必须进入项目自有 guard：先检查 atomic poison，`catch_unwind` 后原子 poison RuntimeIdentity，并拒绝后续业务调用；Swift façade 收到 internal panic error 时也立即使本地 RuntimeIdentity 失效。
- 只有被证明具备事务边界、不会留下部分 mutation 的独立 worker 才允许域级恢复；否则关闭整个 core，从 snapshot+journal 重建。
- 若恢复策略依赖 unwind，release profile 必须锁定并验证 `panic = "unwind"`。`panic=abort`、OOM、stack overflow、SIGSEGV 和 native UB 仍会终止 App。

### 14.2 拆进程触发器

满足以下任一并有测量/事故证据时，才引入局部 XPC/RPC：

- 托管不可信插件、编译器或高崩溃率 native code；
- UI 重启时 Agent/session 必须继续存活；
- 出现真实独立 headless server 或多前端共享 authority；
- 单进程 crash budget 无法接受且 `catch_unwind`/重建不足；
- 安全边界明确要求不同 entitlement/sandbox。

优先只隔离问题域，而不是把整个 core 预先改为 daemon。外部进程协议必须使用项目自有 schema，不复用 UniFFI 内部格式。

## 15. 测试与分层接受门槛

### 15.1 行为对齐

- 现有约 27 万行 Swift 测试是行为线索和合同，其 baseline 冻结在 §3.3 的 fork point；不要求机械翻译成 Rust，也不追随上游 fork 后的测试演进，借鉴的上游改动按 §3.3 自带测试。
- 测试机制（已裁决）：双层——golden corpus 从 fork-point 测试提取、脱敏后入库，`cargo test` 直接消费构成秒级快环；Swift XCTest 经 `AgentryCoreBridge` 跑 FFI/集成/parity 慢环；proto decoder、apply-edits、regex 输入增加 cargo-fuzz/proptest。
- 纯函数域复用 fixtures/goldens，要求明确记录每个有意差异。
- 状态域用确定性 command/event sequence 测试 revision、CAS、cancel、overflow、resync 和 persistence。
- 迁移期可使用离线或 debug-only dual-run；对齐完成后删除旧实现，避免永久双轨。
- MCP、Agent、FSEvents 和多窗口保留集成测试，不以 unit test 代替生命周期验证。

### 15.2 Phase 0：UniFFI 绑定技术接受门槛

Phase 0 只判断“UniFFI 是否可作为 raw binder”，不要求尚未迁移的 workspace/Agent/FSEvents/MCP 领域已经完成生产切换。

1. **Swift 6 gate**
   RepoPrompt 形状的 Core/Record/Error/Subscription/HostRequest 接口通过 strict concurrency、actor data-race checks 和 warnings-as-errors；禁止 async foreign trait，不用 `@preconcurrency` 掩盖问题。

2. **Admission/cancel gate**
   synthetic operation 覆盖 cancel-before-admission、pending、wake/ready、terminal、重复 cancel 和 fingerprint collision；随机竞态至少 10,000 次，启动数与 drop/terminal 数一致，无 operation/continuation 残留，control lane 在 data lane 饱和时仍可用。

3. **Queue/wake/lifecycle gate**
   synthetic bounded queues 覆盖 count/byte overload、oversize event、reserved terminal marker、`hasMore` drain、FD EAGAIN、rearm-and-recheck、重复/并发 close、RuntimeIdentity replacement 与 App shutdown；task、FD 和 subscription 全部有界退出。

4. **代表性 payload microbenchmark gate**
   从当前实现冻结若干脱敏样本（文件树 batch、codemap、搜索结果、transcript），比较 typed DTO 与候选 bytes schema（默认候选已裁决为 Protobuf/SwiftProtobuf，见 §18 未决问题 1）。先测并冻结当前 Swift baseline，再在看到 Rust candidate 结果前登记绝对 SLO 与允许 delta；记录 wall/CPU、Instruments allocations、malloc bytes、峰值 RSS、decode/apply signpost。

5. **Error/panic gate**
   验证 domain error、non-throwing export 审计、项目自有 panic guard、atomic poison、旧 RuntimeIdentity 拒绝和 `panic = "unwind"` release 行为；不要求 Phase 0 已实现真实领域 journal rebuild。

6. **Build/link gate**
   `aarch64-apple-darwin` staticlib、`CAgentryRustCore`、SwiftPM、生成 Xcode workspace、debug/release dead-strip、普通 module map、dSYM/Rust symbolication 可复现；明确验证不会请求或生成 x86_64 artifact。若 direct archive integration 失败，记录证据后验证单 slice XCFramework fallback。完整 notarization/Sparkle 验证在首次影响发布边界的 domain cutover 前执行。

7. **Codegen/identity gate**
   固定版本 clean regeneration 零 diff；旧 bindings 对新 ABI 由 UniFFI checksum 失败；同 API 的错误 archive/schema 由 `CoreBuildFingerprint` 握手失败。

8. **Decoder security gate**
   候选 payload decoder 对未知版本、超大声明长度、截断、非法 enum、压缩炸弹与随机 fuzz 输入 fail closed，并验证最大内存预算。

### 15.3 每个领域的 production cutover gate

通过 Phase 0 只允许继续试点。每个 Phase/领域在成为唯一事实源前还必须单独证明：

1. **唯一 mutation authority**：明确 Swift 或 Rust 哪一侧写入；shadow/dual-run 只读，不允许 dual-write。
2. **行为 parity 与知情漂移**：正确性语义（edits、路径解析、revision/CAS、错误、取消、恢复）必须 parity；表现性行为按决策 12 允许 Rust 重新定义，但每项漂移列入有意差异清单并有新行为测试。
3. **性能 SLO**：冻结同一 fixture 的现有 Swift baseline，然后在 candidate 结果揭晓前登记绝对 SLO/允许 delta；UI 还需 MainActor frame/apply 预算。
4. **持久化与跨进程 ownership**：涉及 canonical storage 的域必须先通过 §7.3 的单 writer lease gate。
5. **拓扑 parity**：凡 app/headless/auto、窗口或 connection scope 可达的能力，所有相应模式必须同步 cutover，或明确 fail closed。
6. **协议单一来源**：迁移期只允许一个 canonical tool/payload catalog；生成物带 schema/build fingerprint，禁止 Swift/Rust 双 catalog 漂移。
7. **安全与恢复**：path fencing、capability allowlist、decoder limits、crash/restart、stale generation 和 durable migration 通过。
8. **发布边界**：受影响 product 的 coordinated arm64 build/test/smoke，以及需要时的 codesign/notarization/Sparkle 验证通过（发布架构已按决策 9/13 提前收敛为 arm64-only）。
9. **观测 parity**：该域现有诊断能力（breadcrumb、latency 记录、debug 设置键）在 Rust 侧有对等物（§11.7），Sentry 与 signpost 链路经过验证。
10. **止血机制（已裁决：beta 浸泡 + 只向前修）**：cutover 版本先发布到 beta channel（§13.5 建立）浸泡，稳定后晋升 stable；不保留 per-domain 回退开关，不承诺降级路径，生产问题以快速热修向前解决；旧实现随 cutover 变更删除，无开关维护窗口。
11. **持久化降级政策（已裁决：精简版）**：该域每个 durable store 带 schema version 戳；旧版本读到更新 schema 一律 fail-closed（拒绝加载并明示，不静默损坏）；仅 journal 类关键 store 在首次写入新 schema 前做一次性自动备份；不提供永久向后兼容写。

每个 Phase 的退出记录必须链接 gate 证据，而不是只写“测试通过”。

### 15.4 接受与拒绝

§15.2 全部通过后，可另行 ADR 将“UniFFI raw binder”改为 Accepted；这不等于批准全面重写。任一关键技术 gate 无法在不 fork/大改 UniFFI templates 的前提下通过，则选择手写窄 C ABI，并保留本文的 façade、command、operation、subscription 和 data-plane 设计。

## 16. 迁移路线图

前置：Gate −1（上游关系）已按 §3.3 裁决为 hard fork，parity baseline 冻结在 fork point；以下 Phase 不受“保持上游可 merge”约束。终态范围已裁决为全量（决策 11）：Phase 0–7 全部为承诺范围，各 Phase gate 照常生效；身份重置与 arm64-only 切换（决策 9/13）先于 Phase 0 以发布动作形式执行。

### Phase 0 — FFI 与运行时骨架

建立 Cargo workspace、`agentry-ffi`、private generated target、Swift façade、自有 Tokio runtime、caller-generated operation ID、cancel-before-admission、有界 drain、wake source 和 HostRequest skeleton。只使用测试/诊断入口验证，不把未验收领域切到生产路径。

**退出标准：** §15.2 全部通过，形成 UniFFI raw binder Accept/Reject ADR。

### Phase 1 — 小型确定性叶子域

优先迁移路径策略、RegexCore 等小型纯逻辑模块，验证 typed control plane、同步 borrowed bytes、golden 与发布集成。

**退出标准：** 该域通过 §15.3，旧实现可删除。

### Phase 2 — Codemap、diff 与 apply-edits

迁移 tree-sitter/codemap、diff/apply-edits 等可离线回放的计算域。authority 和 persistence 暂留 Swift，Rust 以纯 service 方式提供结果。

**退出标准：** 该域通过 §15.3，fixtures/goldens/dual-run 与真实仓 SLO 达标。

### Phase 3 — GUI process runtime 与只读投影

在 GUI 内引入 process-wide Rust runtime 与 per-window subscription，先 shadow/迁移 workspace inventory、search 和 read projection。Swift 仍是 mutation authority；禁止 Swift/Rust 双写，不把本阶段冒充 headless cutover。

**退出标准：** GUI 多窗口、atomic bootstrap、delivery cursor、gap-resync、echo suppression 和 lifecycle 通过；mutation authority 未漂移。

### Phase 4 — Host broker、运行拓扑与存储前置条件

完成 Host Capability Broker；接通 app transport 和“每顶层进程一个 direct runtime”的 headless plumbing；验证 auto 在 initialize 前探测并固定进程生命周期；选定 canonical storage 的 lease/lock/CAS/reload/fail-closed 策略。

已裁决：Phase 4 起 MCP/tool catalog 的 canonical source 移交给 `agentry-proto`（Rust 类型 + 导出语言中立 schema），Swift 侧从生成物消费；Phase 4 之前当前 Swift schema 仍是唯一 canonical，期间禁止维护第二份手写 Rust catalog。

**退出标准：** app/headless/auto 与 capability security parity 通过，跨进程 writer 策略可证明；仍未切换的领域继续由 Swift 唯一 mutation。

### Phase 5 — Workspace authority、persistence 与 MCP domain cutover

在 revision、CAS、journal、root lifecycle、恢复和跨进程 writer gate 齐备后，切换 selection/context/workspace mutation authority。GUI 与所有可达 headless/MCP 路径同步切到同一 Rust domain contract；不能让旧 Swift authority 与新 Rust authority 同时写 canonical storage。

**退出标准：** 该域通过 §15.3；Rust 是 GUI/headless 的唯一领域事实源，旧 Swift authority 和重复 catalog 被删除。

### Phase 6 — Agent provider 逐个迁移

逐 provider 迁移 state machine、process supervision 和 transcript data plane，保留 send/interrupt/shutdown/permission 合同。每个 provider 单独 cutover，不以一个 provider 的成功推导全部 provider 等价。

**退出标准：** 每个 provider 通过 §15.3，进程、信号、权限、恢复和会话持久化对齐后才删除 Swift 实现。

### Phase 7 — Watcher 与收尾

最后基于证据决定 FSEvents 是否下沉；若迁移，先以 mailbox/watermark/barrier parity harness 证明 callback、drain、overflow 和 freshness 语义。清理已替代的 Swift service/ViewModel，保留 Views、projection stores 和 macOS host adapters。

**退出标准：** watcher 若切换则通过 §15.3；所有临时 dual-run/shadow path 删除。

## 17. 风险矩阵

| 风险 | 概率 | 影响 | 缓解 |
|---|---:|---:|---|
| UniFFI pre-1.0 breaking change | 中 | 中高 | 精确锁版本、生成 diff、单一 `agentry-ffi`、独立升级 lane |
| Swift 6 async/Sendable 缺口 | 已确认部分存在 | 高 | 私有 raw target、手写 façade、禁 async foreign trait、Phase 0 strict gate |
| Swift Task 取消不传播/lost cancel | 已确认 | 高 | caller-generated ID、cancel tombstone、control lane、竞态 soak |
| FD missed wake/oversize livelock | 中 | 高 | `hasMore`、rearm-and-recheck、oversize outcome、wake soak |
| 大 DTO 序列化/复制 | 确定存在 | 高 | 批量、分页、独立 bytes schema、benchmark、证据触发 fast path |
| MainActor/platform callback 冲突 | 高 | 高 | HostRequest/HostResponse，不反调 Swift 对象 |
| runtime shutdown/task 泄漏 | 中 | 高 | 项目自有 runtime、task registry、非阻塞 beginShutdown、生命周期 gate |
| Arc handle 泄漏/close 竞态 | 中 | 高 | 少量 handle、typed ID/显式 close、随机并发 soak |
| panic 后状态不一致 | 中 | 高 | 项目自有 export guard、`panic=unwind`、RuntimeIdentity poison、journal rebuild |
| 同 ABI 错误 Rust artifact | 中 | 高 | UniFFI checksum + `CoreBuildFingerprint` 双层握手 |
| arm64 archive/link/符号化/签名失败 | 中 | 高 | conductor arm64 release gate、direct archive fail-fast、dSYM/签名验证 |
| authority scope 漂移 | 中 | 极高 | RuntimeIdentity/scope/stream/cursor 显式建模，多窗口/headless 测试 |
| App/headless 并发写 canonical storage | 中 | 极高 | Phase 4 前强制 lease/lock/CAS/reload 或 fail closed |
| payload decode/压缩资源攻击 | 中 | 高 | 独立 schema 版本、size/ratio limit、fuzz、unknown version fail closed |
| 重写规模导致长期双轨 | 高 | 高 | 按域切换、明确删除门槛、dual-run 只读且临时存在 |
| 单进程无崩溃隔离 | 固有 | 高 | crash budget；证据触发局部 XPC，不用 `catch_unwind` 冒充隔离 |
| 断供上游功能流（hard fork 已接受） | 确定 | 高 | §3.3 借鉴流程；聚焦差异化目标；安全修复强制评估 |
| 借鉴改动落错侧造成 Swift/Rust 双实现漂移 | 中 | 高 | 借鉴只落 canonical authority 一侧；review 时标注目标域归属 |
| 表现性行为漂移未被识别/沟通 | 中 | 中 | 决策 12 知情漂移清单 + 新行为测试 |

## 18. 未决问题

1. 大 payload schema：默认候选已裁决为 Protobuf + SwiftProtobuf，Phase 0 benchmark 验证；不达标再评估 FlatBuffers/项目自有布局；不采用缺少成熟 Swift 端的 postcard。runtime transport、durable journal 和 external wire 分别定义兼容期。
2. 文件树/codemap 是否需要 immutable owned-buffer fast path；只能由 Phase 0 benchmark 决定。
3. wake FD 是 per-core 还是 per-subscription；无论选择哪种，都必须满足 §9.5 的 ownership/rearm/backpressure 合同。
4. Agent 会话持久化：按决策 12 允许在 Rust 侧重设计格式；未决的是 fork 自身版本间是否提供旧 session 读取/导出，或在 cutover 版本明示重置。
5. 已裁决：VCS 后端以 CLI 子进程（git/jj）起步为 canonical（与现有 CLI 后端模型一致，parity 零漂移；初期为 `agentry-domain-workspace` 内部 module）；进程内库化（gitoxide/`jj-lib`）为终态目标而非仅期权，按行为与性能基准分域切换；不引入 git2/libgit2。
6. FSEvents 长期留 Swift adapter 还是迁 Rust；先以现有 watermark/barrier 合同做 parity harness。
7. 已裁决：单 writer lease（§7.3）；lock+CAS+reload 与纯 fail-closed 仅为 Phase 4 证伪 lease 后的备选。
8. 已裁决：Phase 4 起 canonical 移交 `agentry-proto`（Rust 类型 + 导出 schema），Swift 消费生成物；此前维持现有 Swift schema canonical（§16 Phase 4）。
9. 何种 crash/session-survival 指标会正式触发 Agent runtime XPC/daemon 化。
10. 已裁决（决策 13）：更换 bundle identifier、独立 canonical storage 目录、独立 Sparkle feed（新 EdDSA 密钥）；不导入上游/旧数据，首启全新状态。
11. 已裁决：产品名 **Agentry**（完全改名）；app 名、CLI 名、存储目录、feed 与品牌区隔的落地清单见 §13.5。
12. 已裁决：确定性自然排序（case-fold + 数字感知 + 码位 tie-break，§3.4 第 2 条）；icu4x + 中文 collation（拼音序）保留为同 API 后的可逆升级路径。

## 19. 参考资料

### UniFFI 官方

- [UniFFI changelog](https://github.com/mozilla/uniffi-rs/blob/main/CHANGELOG.md)
- [Swift bindings 与 Swift 6 支持](https://mozilla.github.io/uniffi-rs/latest/swift/overview.html)
- [Async/Future 与取消说明](https://mozilla.github.io/uniffi-rs/latest/futures.html)
- [Async FFI internals](https://mozilla.github.io/uniffi-rs/latest/internals/async-ffi.html)
- [Lifting、lowering 与内部序列化](https://mozilla.github.io/uniffi-rs/latest/internals/lifting_and_lowering.html)
- [Proc-macro bindings](https://mozilla.github.io/uniffi-rs/latest/proc_macro/index.html)
- [Swift/Xcode integration](https://mozilla.github.io/uniffi-rs/latest/swift/xcode.html)
- [uniffi-bindgen-swift](https://mozilla.github.io/uniffi-rs/latest/swift/uniffi-bindgen-swift.html)
- [Swift 6 umbrella issue #2448](https://github.com/mozilla/uniffi-rs/issues/2448)
- [Async code Sendable tracking issue #2458](https://github.com/mozilla/uniffi-rs/issues/2458)
- [Borrowed bytes (`&[u8]` / Swift `Data`)](https://mozilla.github.io/uniffi-rs/latest/types/bytes.html)

### 构建与社区布局参考

- [Cargo Workspaces](https://doc.rust-lang.org/cargo/reference/workspaces.html)
- [SwiftPM C language targets](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/creatingclanguagetargets/)
- [SwiftPM mixed-language target 限制](https://github.com/swiftlang/swift-package-manager/blob/main/Sources/PackageLoading/PackageBuilder.swift)
- [UniFFI Starter：`rust/` workspace + generated Swift target + wrapper target](https://github.com/ianthetechie/uniffi-starter)
- [Matrix Rust SDK Apple bindings：xtask + UniFFI + Swift package](https://github.com/matrix-org/matrix-rust-sdk/tree/main/bindings/apple)

### 仓库内现有合同

- `docs/architecture/headless-mcp-runtime.md`
- `Sources/RepoPromptDomainRuntime/RepoPromptDomainRuntime.swift`
- `Sources/RepoPromptDomainRuntime/DomainWorkspaceContextAuthority.swift`
- `Sources/RepoPromptDomainRuntime/DomainWorkspaceModels.swift`
- `Sources/RepoPromptDomainRuntime/DomainInteractionBroker.swift`
- `Sources/RepoPrompt/Infrastructure/MCP/AppShared/DomainWorkspacePresentationBridge.swift`
- `Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemWatcherIngressMailbox.swift`
- `Sources/RepoPrompt/Infrastructure/FileSystem/FileSystemService+FSEvents.swift`
- `Sources/RepoPrompt/Infrastructure/Process/ProcessLauncher.swift`
- `Sources/RepoPrompt/Features/AgentMode/Runtime/Native/NativeAgentRuntimeContracts.swift`
