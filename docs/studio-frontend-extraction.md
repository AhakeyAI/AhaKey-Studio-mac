# 从 origin 拆出 Studio 前端

核对日期：2026-09-20。本文记录拆分前调研与整体方案。第一阶段现已在本地 `dev` 落地，实际代码结构、运行方式和剩余范围见 [独立前端开发说明](studio-frontend.md)；尚未进行 Rust/硬件联调。

## 基线与结论

- 已执行 `git fetch origin`，远端为 `AhakeyAI/AhaKey-Studio-mac`，`origin/main` 为 `2f77109`。
- 当前本地 `main` 为 `bdec7b3`，落后两个提交。差异仅涉及日语本地化、对应 Xcode 工程配置和本地化文档；本文核对的 Swift 源码与 origin/main 一致。
- Rust 仓库当前 HEAD 为 `a4e4b29`，读取了当前工作区的实现。已有 BLE 检索、连接、订阅、命令写入和状态解析雏形，没有 Studio 可连接的 IPC。
- 执行 `cargo check --locked --offline` 失败：`src/ahakey/model_x1.rs:25` 给 `JoinHandle<()>` 类型的 `listener` 赋了 `None`。这只是当前编译阻塞，修复它不等于完成 Runtime。
- 既有 `runtime-studio-current-desktop-design.md` 是较早的未跟踪设计稿，其“Rust 仅检索并打印”的基线已过时；其中功能分工仍可参考，但不能当作已实现协议。

建议保留现有 SwiftUI Studio，以独立 Rust Runtime 持有设备连接。先抽出前端模块和可替换的 Runtime 接口，再接真实 Rust 实现。当前仓库已经从多平台 Desktop 拆成 macOS 工程，剩下的主要工作是解除进程内职责耦合。

本文按“前端继续使用 SwiftUI”设计。如果目标另含 Web/跨平台 UI，键盘画布与 SwiftUI 页面需要另行实现；Rust 后端的决定本身不要求同时重写界面。

## 目标结构

```text
Studio（SwiftUI 进程）
  Views / VibeBar / 权限引导 / 账号页面
      ↓
  StudioModel
    ├─ StudioDraftStore：编辑草稿、本地素材、选中状态
    ├─ RuntimeStore：后台快照、设备状态、操作进度
    └─ RuntimeClient：业务请求、订阅、重连
             ↓ 本机 IPC
Rust Runtime（独立后台进程）
  设备连接 / 状态 / 配置执行 / 资源处理 / Hook / 刷机
             ↓
           键盘

macOS 平台能力：语音、输入监听、文本注入
  过渡期保留 Swift 实现；需要随 Studio 退出继续工作时独立托管
```

Studio 退出不应终止 Rust Runtime 或它已受理的设备操作。安装包仍可一起分发 Studio、Runtime 和辅助程序；独立进程、独立构建与独立安装包是不同的选择。

## 实际耦合点与文件归属

以下路径相对仓库根目录；行号以本次核对源码为准。

| 当前位置 | 现状 | 拆分动作 |
|---|---|---|
| `AhaKey Studio/App/AhaKeyWorkspaceView.swift:6` | 工作区直接创建 BLE manager | 改为注入应用级 `StudioModel`，统一管理连接生命周期 |
| `AhaKey Studio/App/RootView.swift:5` | 页面和权限引导依赖 BLE manager | 读取 Runtime 设备/权限投影，系统设置跳转留在平台层 |
| `AhaKey Studio/Features/Studio/AhaKeyStudioView.swift:9` | 5,057 行，直接依赖 BLE、Agent、语音和账号 | 先移出行为与状态，再按画布、检查器、状态栏等拆 View |
| 同文件 `:2185`、`:2322` | 上传图片、组装配置命令、等待 ACK、保存设备 | 前端提交配置意图；执行顺序与确认规则迁入 Rust |
| 同文件 `:2090` 附近 | Studio/Agent 之间切换 BLE owner | Rust 接管后删除该交互及过渡状态 |
| 同文件 `:2410` 附近 | View 在连接后触发默认 OLED 自动上传 | 默认资源安装成为显式 Runtime 配置策略；不由 View 出现触发硬件写入 |
| `AhaKey Studio/Features/Studio/AhaKeyStudioModels.swift` | 展示、草稿存储和固件字节模型混合 | 保留展示与草稿；新增独立请求/响应 DTO；移出固件编码 |
| `AhaKey Studio/Services/Bluetooth/AhaKeyBLEManager.swift` | BLE、Agent 文件轮询、通知展示混合 | BLE/轮询退出前端；`SwitchStateNotifier` 等展示能力改订阅 RuntimeStore |
| `AhaKey Studio/Services/Bluetooth/AhaKeyProtocol.swift` | 命令编解码、`IDEState`、`HIDUsage` 共文件 | 编解码迁 Rust；状态名和键码显示拆入前端领域/展示模块 |
| `AhaKey Studio/Features/OLED/OLEDFrameEncoder.swift` | GIF 到设备像素编码 | 设备编码归 Rust；文件选择与动画预览留 Studio |
| `AhaKey Studio/Services/Agent/AgentManager.swift` | 1,802 行，包含 owner 切换、安装启动、Hook 修改 | 分离 Runtime 安装启动入口；Hook 管理迁后台；删除 owner 切换 |
| `Tools/Agent/` | 旧 Swift daemon 与工具 Hook | 迁移执行能力；兼容期可保留只转发的 Hook CLI，不再持有 BLE |
| `AhaKey Studio/Features/Studio/VibeBarBridge.swift:11` | 直接订阅 BLE 和语音 singleton | 改订阅 RuntimeStore/语音状态；`Modules/VibeBar` 继续保留 |
| `AhaKey Studio/Features/Firmware/` | View 创建 flasher，执行 `wchisp` | 保留交互和进度展示；预检、擦写及进程管理迁 Runtime |
| `Modules/AhaKeyPluginKit/PluginHost.swift:126` | 通过旧 `/tmp/ahakey.sock` 查询拨杆 | 更换为 Runtime adapter，继续保留插件 stdio 协议 |
| `sdks/typescript/` | 当前是插件 SDK | 不能作为已实现的 Runtime SDK 使用；后续单独补 Runtime client |
| `AhaKey Studio/Features/Account/` | 云账号交互 | 首期保留，设备拆分不要求把注册、支付也放进 Rust |
| `AhaKey Studio/Features/Voice/`、`AppDelegate.swift` | App 启动语音监听，执行 macOS 系统能力 | 单独隔离平台实现；首期若留进程内，明确退出 Studio 会停止语音 |

不建议把整个 `AhaKeyBLEManager` 的方法逐个复制为 RPC。这样会迫使前端继续了解字节命令、Flash 地址、写入顺序和错误恢复。

## 前端先落地的模块

建议起步使用普通目录与少量明确 target，不必为每个目录都建独立 Swift package。

```text
AhaKey Studio/
  App/                         # 应用组装、窗口和菜单
  Features/                    # 编辑和展示
  Models/                      # 前端业务模型与显示转换
  State/
    StudioModel.swift          # 用户动作入口，协调草稿和后台状态
    StudioDraftStore.swift     # 旧本地数据迁移、未提交编辑
    RuntimeStore.swift         # 权威状态投影，不混入用户草稿
  Runtime/
    RuntimeClient.swift        # 面向业务的 Swift 接口
    RuntimeDTOs.swift          # 仅传输数据，不依赖 SwiftUI/CoreBluetooth
    IPCRuntimeClient.swift     # 真实 IPC adapter
    MockRuntimeClient.swift    # 离线开发 adapter
  Platform/macOS/             # 设置跳转、语音等平台接入
  Resources/
  Localization/
```

Mock 与 IPC 实现共用一个业务接口。若迁移期还要保持旧版可用，可临时提供 Legacy adapter；它只能在明确的旧版运行模式启用，Rust 模式下禁止再启动 Swift BLE owner，也不能断线后自动回退到直连。

## 第一版接口范围

沿用已有设计稿的本机 WebSocket + JSON-RPC 方向；先冻结下面这些语义与固定 JSON 样例，再开发两端。此处方法名是提议，并非 Runtime 当前能力。

| 方法族 | 前端需要得到的能力 |
|---|---|
| `runtime.hello`、`runtime.subscribe` | 版本与能力协商；原子快照和后续事件 |
| `device.discover/connect/disconnect` | 提交连接意图；区分 IPC 连接和设备连接 |
| `configuration.get/apply` | 读取带基线的配置、提交修改；返回 operationId |
| `operation.get` | 断线重连后查询同一操作结果，不盲目重发 |
| `device.preview/endPreview` | 临时预览，由 Runtime 负责超时和恢复 |

第一批交付状态展示和无图片的配置保存。资源上传、Hook、语音、刷机分批扩展，不让尚未实现的方法出现在能力列表里。

必须在接口中说清楚：

- Runtime 连接状态、键盘状态、用户编辑草稿分开；未知电量/拨杆不能填 0。
- `configuration.apply` 传 shortcut/macro/disabled、描述、灯效等业务字段，不传 BLE bytes 或整份现有 `StudioDraft`。
- 当前模型的宏延迟是 3ms 单位；转换为毫秒需显式迁移。灯效固件编号不作为 UI 的设备执行依据。
- 亮度是设备级配置。现有草稿虽按 mode 存亮度，命令本身没有 mode 参数。
- `localAssetPath`、本地化文案、UI 状态不跨进程。资源上传后用 resourceId 引用。
- 受理不等于执行成功；操作进度以 Runtime 为准。保留 operationId、基线冲突和部分失败语义。
- IPC 断线后用新快照恢复后台投影，保留未提交草稿；不能把默认草稿或上次提交值当作设备读回。
- 本机 endpoint 发现、认证、协议版本和实际权限 owner 需要一并定义，不能只写一个固定端口常量。

## 按可验收结果分步实施

1. **前端可独立运行。** 从更新后的 origin/main 开 `codex/studio-frontend` 工作分支；保留中英日资源。抽出 DTO、Store、RuntimeClient 和 Mock，页面不再直接读取 BLE manager。Runtime 缺席时能打开、编辑草稿、显示不可用状态；Mock 可演示连接、进度、失败。
2. **Rust 状态链路。** 先修复编译并实现 hello/subscribe、真实设备连接与状态通知。停止旧 BLE owner 后再交给 Rust；切换期间保留旧发行版本可回滚，避免同时运行两套设备 owner。
3. **配置闭环。** 迁移无图片配置、互斥宏/快捷键层清理、按键描述、灯效、全局亮度及逐条 ACK。Studio 只提交配置、显示操作。随后移除主界面切换 BLE owner 的代码。
4. **完整功能迁移。** 依次接入 OLED 资源与预览、Hook/插件查询、刷机；隔离语音 host 并保持权限引导与实际执行进程一致。修正默认 OLED 自动写入和草稿立即改变语音路由等隐式行为。
5. **工程与发布清理。** 移除 Studio 对旧 `AhaKeyConfigAgent` 的构建依赖和 `Embed Agent`；迁移刷机资源复制/校验步骤；更新 CI、安装与架构文档。本仓库 `docs/architecture.md` 仍描述旧多平台目录，需同步修订。

Xcode 使用文件系统同步目录。仅把旧实现挪到 `AhaKey Studio/Legacy` 并不能确保它退出编译：应迁出同步根、设置 target membership exception，或放入明确的 Legacy target，并同步调整依赖测试。

第一步可以做出独立可开发的前端，但只有后续真实设备链路完成后才能替代现有完整发行版。未接入的功能必须明确不可用，不能用 Mock 成功冒充设备写入成功。

## 完成判据

- 前端 target 不包含 CoreBluetooth、设备命令编解码、Flash 布局或旧 Agent 的连接轮询。
- 真实运行模式下 Rust 是唯一设备 owner；关闭 Studio 后，后台连接和已受理操作仍能继续。
- Swift/Rust 使用相同 JSON fixtures 验证协议；前端与 Mock 可独立构建和开发。
- 重连不丢草稿、不重复写入；外部修改产生冲突提示；结果未知与写入成功有不同展示。
- 真机覆盖当前模式/全部模式保存、宏与快捷键互转、OLED 中途断线、Hook 与配置并发、刷机不可取消阶段。
- 语音进程退出行为、权限归属和前端提示一致；旧草稿、素材路径和用户集成配置迁移可追踪。

最初调研仅核对源码、远端差异并运行 Rust 编译检查。后续按用户要求创建本地 `dev` 并实施第一阶段；未运行设备命令或刷机。
