# Runtime 与设备交互：按 main 的 Swift 实现迁移

依据：`AhakeyAI-desktop` 本地 `main`，提交 `46562633b094db616cfa760f0e4bd2c8891c6581`。这是对客户端实际发送/接收代码的审阅，不是固件源码审计，也不是实机协议认证。当前 checkout 是另一个分支，不能把二者混成同一版本。

主要依据为该提交的 `ahakeyconfig-mac/Sources/BLE/AhaKeyProtocol.swift`、`AhaKeyBLEManager.swift`，以及 `Views/AhaKeyStudioView.swift` 的命令组装和图片布局代码。

## 1. 交互分层

```text
Studio / 多语言 SDK
  → JSON 业务操作 + 图片资源
Runtime
  → 每设备一个命令调度器
  → AhaKey 二进制编解码与图片上传流程
  → BLE 平台实现
键盘
```

Runtime 接管现有主 App 和 Agent 两边的设备通信。Studio 不接管/释放蓝牙，也不计算 Flash 地址。按此 Swift 基线可以实现 BLE；它不提供 USB 配置收发的依据，不能因此宣称 USB 已支持。

## 2. 建立连接

现有 Swift：已知 peripheral UUID → 系统已连接的 7340 服务设备 → 按服务扫描，再按 AhaKey 名称前缀筛选。迁移时保留系统已连接设备检索；不能只依赖广播扫描。Runtime 应持久化设备身份，不能在设备改名后只靠名称重新识别。

连接完成后发现服务和特征：

| UUID | 用途 |
|---|---|
| 7340 | 自定义主服务 |
| 7343 | 写命令 |
| 7341 | 写图片原始数据；Swift 也尝试订阅这里的通知 |
| 7344 | 命令结果、状态、图片块 ACK 通知 |
| 7342 | 此客户端没有实际读写用途 |
| 180F / 2A19 | 电量 read / 可用时 notify |
| 180A / 2A26、2A24 | 固件字符串、型号 |

Runtime 的 ready 必须在命令通道可用、所需通知订阅成功之后产生。Swift 当前发现 characteristic 就设置 notifyCharReady，然后调用 setNotifyValue；它并没有等待订阅完成回调，因此不能直接复制这个 ready 判定。

随后发送 0x00 状态查询，以及按 mode=0…3 顺序发送 0x83 图片状态查询。图片写权限要等布局信息和该设备适配规则确认，普通状态展示不必等全部图片查询。

本 main 没有 0x99 能力协商路径。不要套用 upstream/runtime 的 session 上传和双套任务图能力。未识别设备只查询，不依据一个模糊版本字符串自动套用固定写入布局。

## 3. 字节格式和命令

命令：`AA BB | cmd:u8 | payload | CC DD`。

普通回包：`AA BB | cmdEcho:u8 | status:u8 | payload | CC DD`，Swift 按 status=0 判断成功。

0x00 是例外：cmd 后直接是电量、信号、固件主/次版本、工作模式、灯光模式、拨杆，以及可选亮度；第一个字节不是 status。缺少亮度时当前 Swift 填 35，Runtime 应向外报告未知，不能把默认值当成读回事实。蓝牙 readRSSI 与协议 signal 字段不要混为同一来源。

| 操作 | cmd 与 payload |
|---|---|
| 状态查询 | 00，无 payload |
| 改名 | 01，名称 UTF-8；当前编码截前 21 字节 |
| Appearance | 02，当前 Swift 只编码 u8；不擅自改为通用 u16 布局 |
| 保存配置 | 04，无 payload |
| 快捷键 | 73，`73 mode keyIndex hidCodes...` |
| 宏 | 73，`74 mode keyIndex action param...` |
| 按键描述 | 73，`75 mode keyIndex ascii...`，最多 20 字节 |
| 图片块准备 | 80，`flag:u8 chunkLength:u16LE address:u32LE` |
| 图片块结果 | 81，设备通知，成功 status=0 |
| 动画绑定 | 82，`mode:u8 startIndex:u16LE frameCount:u16LE intervalMs:u16LE` |
| 图片状态查询 | 83，`mode:u8` |
| 灯效映射 | 84，`mode:u8 effect[9]`，依 IDEState 0…8 排列 |
| 全局亮度 | 85，`brightness:u8`，1…100 |
| IDE 状态 | 90，`state:u8`，当前枚举 0…8 |
| 临时灯效预览 | 91，`effect:u8` |
| 工作模式切换 | 92，`mode:u8`，当前 0…3 |

0x91 已用于灯效预览。Swift 的 setSwitchStateViaBLE 只记录日志，虚拟拨杆属于软件覆盖，不能把它编码成旧 0x91 指令。

Runtime 应在编码前检查名称 UTF-8 字节长度、宏长度、模式和灯效范围；例如不要复制 prefix(21) 导致中文名称截断半个字符。现有“最多 98 字节”的键码/宏限制有代码注释，但构造函数未完整执行限制，需要接口侧落实。

## 4. 配置写入与确认

当前 View.commandsForModes 的行为必须保留：

- 改为宏：先清空快捷键层，再写宏。
- 改为快捷键/无按键：先清空宏层，再写快捷键/空快捷键。
- 然后发送按键描述；描述实际发送到键盘，不是仅存在 Studio 的元数据。
- 每模式写 9 个状态的灯效映射；最后设置一次全局亮度。
- 整体写入时先上传改变的图片，再写以上配置，最后发送 0x04 保存。

现有 UI 把亮度放在每模式草稿中，但命令没有 mode 参数，实际只发送 modes[0] 的亮度。新接口必须改成设备级全局亮度，不能对外承诺每模式独立亮度。

普通 Swift 批写每隔 50ms 发一条，不逐条等待设备 ACK。更具体地说，drainWriteQueue 在发最后一条命令之前就触发 batch completion；View 再等 250ms 后把整份草稿标为已同步。这不是持久保存成功的可靠证据。

新 Runtime 采用每设备一个串行调度器，读状态、临时状态、配置、图片都经过它。现有回包没有 requestId，至少同 opcode 不能有多个请求在途；迁移初期统一只允许一个需响应的命令在途，0x83 还核对回显 mode。注册等待者后才发送。

确认分三层：系统接收写请求 / 设备命令 ACK / 设备持久保存。对于有确认语义的指令等待实际回包；0x04 回包是否证明 Flash 已持久化，必须额外核对设备行为，当前 Swift 不能证明。没有证据时返回 sent/unknown，不能伪造 writeConfirmed 或 verified。这也意味着现有 main 不能支持任意配置完整读回或设备原子事务的承诺。

超时/断线会结束当前等待并停止其发送任务。因为回包无事务 ID，超时后不能立即发送同 opcode 并把迟到 ACK 算给新请求；应使旧会话失效、重建通知链，再重新查询必要状态。设备断线或能力变化后不复用旧 characteristic/回调。

## 5. 图片上传

Swift 的常量是：160×80，RGB565 大端像素，每帧有效像素 25,600 字节，Flash 槽位跨度 28,672 字节；保留前 10 个槽位，每模式最多 70 帧，起点 `10 + mode*70`。GIF 输入上限为 2 MiB。

这些是此客户端的布局假设，不等于已验证的所有出厂固件容量。0x83 返回 mode/startIndex/picLength/frameInterval/allModeMaxPic，Runtime 应保留这些值并校验布局；不能只保留帧数后忽略真实范围。

迁移流程：

```text
取得模式的图片状态与已确认布局
→ 解码 GIF 为 160×80 RGB565 帧
→ 每帧切为最多 4096 字节的块
→ 7343 发送 0x80，等待成功回包
→ 7341 发送该块原始像素数据
→ 等待设备 0x81 成功回包
→ 下一块、下一帧
→ 7343 发送 0x82，绑定模式/起点/帧数/间隔，等待成功回包
→ 配置保存步骤 0x04（持久化语义仍需验证）
```

每帧地址为 `(startIndex + frameIndex) * 28672`，块地址在此基础上加 0、4096、8192…；最后一块 1024 字节，不补齐像素数据到整个槽位。

4096 是逻辑 Flash 块，180 是 BLE 单次写的软上限，二者不要混淆。Swift 用 `min(系统对应 writeType 的最大写长度,180)` 分包，包间 12ms；DATA 优先 withResponse，CMD 优先 withoutResponse。新 Runtime 根据平台 write 完成/可写通知控制流量，迁移初期保留 180/12ms 作为兼容初值，未经测量不盲目加速。

系统 withResponse 只说明 GATT 写入层结果，图片块还需 0x81。进度按确认完成的逻辑块增加，不按调用 write 次数增加。编码可逐帧进行，避免一次持有所有 RGB565 帧及副本。

当前 Swift 对 0x80/0x82/0x83 和 0x81 等待设置 5 秒计时，但 TaskGroup 的取消没有主动结束挂起 continuation，超时后的子任务退出存在风险；Runtime 必须使用能真正终止等待并清理状态的超时路径，不能只移植表面的 5 秒常量。

本路径没有 upload sessionId、块序号或断点续传命令。重连后不能从“最后发出的字节”继续；应把结果标为部分/未知，重核布局后重新准备不确定块，或按适配策略重传整个目标资源。已经覆盖的原图不保证可回滚。

## 6. 长期运行

现有 Swift 每 1.5 秒查询状态，上传期间或已有协议等待时跳过；每 5 秒读 RSSI；重连由独立定时和断线回调驱动。Runtime 可先沿用状态采样频率，RSSI 只在诊断订阅时采样，避免无意义后台工作。

上传期间暂停状态查询意味着拨杆值可能变旧。向 Studio 推送缓存时附 observedAt/stale；需要最新拨杆的批准查询不能拿旧缓存当刚读到的值。暂时无法读取时返回 unavailable。

蓝牙会话由 Runtime 生命周期管理，不随 Studio 开关窗口而重连。多客户端请求进入同一个设备调度器。相同瞬时 IDE 状态可合并；不能跨越需确认的配置步骤合并写操作。

## 7. 对 Studio IPC 提案的修正

此前 `runtime-studio-protocol-v1.md` 基于另一个分支，应用到 main 时需按本文修订：

1. 增加设备改名、工作模式切换、灯效预览、全局亮度、显式连接意图、图片状态查询。
2. 灯光页面中的亮度改为全局字段，共享同一冲突版本；按键 description 计入设备写入结果。
3. main 的单动画/70 帧配置与 upstream/runtime 的任务套图/30 帧 profile 分开表达，不能统一写死一套。
4. “全部模式保存”使用一个显式范围的配置操作，Runtime 内部顺序执行并最后保存；不宣称多模式原子性。页面修改仍可保留，但应满足整组指令和全局字段依赖。
5. 不能直接承诺 main 固件支持能力协商、完整配置读回、可恢复 session 上传、原子保存或 USB 配置。
6. IPC operationId 只能避免 Runtime 重复创建操作，不能凭空给设备 ACK 增加事务身份。

本次没有修改 Swift、烧录设备或运行硬件命令。上述 Runtime 行为是基于实际 Swift 收发路径提出的迁移设计。
