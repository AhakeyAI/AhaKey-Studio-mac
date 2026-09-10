# AhaKey 硬件连接与 Rust 库成熟度

调研日期：2026-09-08。分析对象：`AhakeyAI/desktop` 的 `upstream/runtime`，固定提交 `13240bb8d1ff92061eddf0a9b7d70c77d29e8b8d`。从本地 Git 对象读取该分支，未切换工作区。本文保存在当前 AhaKey Studio 工作区。

**结论：USB HID 的 Rust 接入方案成熟度较高；BLE 的常规功能已经齐全，但 AhaKey 最依赖的恢复与连续传输能力，需要对新版本进行实机验证。现有证据支持 Rust 进入候选实现，尚不足以承诺重写后比现有 Swift 更稳定或更省维护。**

这里的“成熟度”综合接口覆盖、维护历史、平台实现和项目适配缺口。没有用星数或版本号直接打分。本次是源码与官方资料调研，未连接键盘、未执行跨平台构建或长时间硬件测试。

## 目前代码实际做了什么

| 部分 | 已实现内容 | 实现边界 |
| --- | --- | --- |
| macOS Runtime BLE | 扫描、找回系统已连接设备、按已知 UUID 重连、服务发现、通知订阅、设备身份识别、能力协商、状态轮询 | 实际调用 CoreBluetooth，存在完整设备读写路径 |
| 设备命令 | 读取电量、固件版本、工作模式、灯光和拨杆状态；发送 AI 状态；写入键位、宏、描述、灯效和亮度 | AhaKey 自定义协议，通用蓝牙库不负责解释 |
| OLED 上传 | 图片编码、按固件和系统上限分包、准备写入、等待固件 ACK、按 session 判断回包、中止上传、兼容不同固件 | 不是一次普通 GATT write；迁移必须保留协议语义 |
| macOS Runtime USB | 64 字节 HID report 编解码、BLE/USB 路由选择条件 | 在该分支 Runtime 中未找到实际 IOHID 打开/读写实现，当前上传落地仍走 BLE |
| Windows Java USB | JNA 调用 SetupAPI、CreateFile、ReadFile、WriteFile，独立读取线程 | 是实际 USB HID 实现，当前识别 `413C:2107` |
| Windows BLE | Java 客户端通过 TCP 使用另一个 C# BLE 桥；桥使用 Windows GATT 接口 | 不能把 Java 中的 Socket 当成跨平台原生 BLE 库 |
| Ubuntu Java USB/BLE | USB 可以查找设备，但 `writeReport` 只打印 stub 日志；BLE 管理器使用 TCP 桥接口 | 此处没有完成 Linux USB 收发；也不能据此认定 Linux 本地 BLE 已接通 |

代码依据：[macOS Agent](https://github.com/AhakeyAI/desktop/blob/13240bb8d1ff92061eddf0a9b7d70c77d29e8b8d/ahakeyconfig-mac/Sources/Agent/AhaKeyAgent.swift)、[设备程序步骤](https://github.com/AhakeyAI/desktop/blob/13240bb8d1ff92061eddf0a9b7d70c77d29e8b8d/ahakeyconfig-mac/Sources/Shared/AhaKeyDeviceProgramSteps.swift)、[macOS USB codec/selector](https://github.com/AhakeyAI/desktop/blob/13240bb8d1ff92061eddf0a9b7d70c77d29e8b8d/ahakeyconfig-mac/Sources/Shared/AhaKeyUSBConfiguration.swift)、[Windows USB](https://github.com/AhakeyAI/desktop/blob/13240bb8d1ff92061eddf0a9b7d70c77d29e8b8d/ahakeyconfig-win-java/src/main/java/com/example/ahakey/service/UsbHidTransport.java)、[Ubuntu USB](https://github.com/AhakeyAI/desktop/blob/13240bb8d1ff92061eddf0a9b7d70c77d29e8b8d/ahakeyconfig-ubuntu-java/src/main/java/com/example/ahakey/service/UsbHidTransport.java)、[Ubuntu BLE 客户端](https://github.com/AhakeyAI/desktop/blob/13240bb8d1ff92061eddf0a9b7d70c77d29e8b8d/ahakeyconfig-ubuntu-java/src/main/java/com/example/ahakey/service/BleManager.java)、[C# BLE 桥](https://github.com/AhakeyAI/desktop/blob/13240bb8d1ff92061eddf0a9b7d70c77d29e8b8d/BLE_tcp_bridge/Form1.cs)。

目前实际需要替换的连接接口主要是 **BLE GATT central + USB HID**。配置键位里的 HID usage code 是发送给固件的协议内容，不代表 Runtime 需要接管系统键盘驱动。该 Runtime 的 `startFirmwareUpgrade` 只有请求声明，处理器未实现该分支；不能把未来 ISP/DFU 升级能力算作现有 HID 库已经覆盖。此结论不包含另一个 `feat/firmware-flasher` 分支。[请求处理](https://github.com/AhakeyAI/desktop/blob/13240bb8d1ff92061eddf0a9b7d70c77d29e8b8d/ahakeyconfig-mac/Sources/Agent/AhaKeyAgent.swift#L1109)

## 对应 Rust 方案

| AhaKey 能力 | Rust 对应 | 成熟度判断 | 还需要自己维护什么 |
| --- | --- | --- | --- |
| USB HID 枚举、打开、报告收发 | `hidapi` / hidapi-rs | **较高，优先候选** | 固件协议、接口选择、拔插恢复、平台安装配置 |
| BLE 扫描、连接、读写、通知 | `btleplug 0.13.0` | **功能完整，可进入产品验证** | 设备身份、协商、命令顺序、重连策略 |
| 无广播时找回已连接键盘 | `btleplug::Central::retrieve_peripherals` | **现版已支持，新增能力需验证** | 各系统的设备来源差异、应用层恢复状态机 |
| BLE OLED 连续上传 | `btleplug::Peripheral::write` + AhaKey 协议实现 | **API 可用，项目适配风险较高** | 分包、发送节奏、固件 ACK、session、失败恢复 |
| 连接代际与旧回调隔离 | Runtime 自有状态机 + 库事件 | **没有可以直接替换整段代码的通用库** | 重新建立与现有行为等价的事件归属机制 |

### USB：`hidapi` 是相对稳妥的部分

Rust `hidapi` 有可追溯至 2016 年的发行记录，2019 年发布 1.0；目前为 **2.6.7，2026-08-27 发布**，2026 年仍有多次更新。其主要基础是 C HIDAPI，而不是新写的一套 USB 驱动。[发行记录](https://docs.rs/crate/hidapi/latest)、[Rust 仓库](https://github.com/ruabmbua/hidapi-rs)

C HIDAPI 为 Windows、Linux 和 macOS 提供实现，分别接入 Windows HID、Linux hidraw/libusb、macOS IOHIDManager；有长期维护基础。[HIDAPI 官方说明](https://github.com/libusb/hidapi)

AhaKey 现有格式是 64 字节报告：`A1/A2 + 长度 + 最多 62 字节内容`。Rust `HidDevice::write` 要求在报告数据前放 report ID；无编号报告填 0。因此现有 Windows 代码里的“0 + 64 字节”与它的接口约定吻合，但读取时是否包含编号应按设备报告描述符处理，不能机械地总丢弃第一个字节。[HidDevice API](https://docs.rs/hidapi/latest/hidapi/struct.HidDevice.html)

接入仍需核对三件事：选择键盘的自定义配置接口；Linux 用户访问权限和 udev 规则；macOS 打开方式是否影响正常打字。架构文档规划 `07D7:501A`、`413C:2107` 和 usage page `0xFF00`，而现有 Windows 实现只识别后一 VID/PID，不能把文档目标当成三个平台都已验证。[AhaKey USB 设计](https://github.com/AhakeyAI/desktop/blob/13240bb8d1ff92061eddf0a9b7d70c77d29e8b8d/docs/ahakey-runtime-architecture.md#L121)

后端建议：Linux 优先评估 hidraw，因为 Rust 文档明确 libusb 后端不提供 `usage_page()`/`usage()`；macOS 评估 `macos-shared-device`，共享访问是显式启用的选项；Windows 的 C 后端与 `windows-native` 应选定一种验证，不能假定行为完全一致。[后端与 feature 说明](https://docs.rs/hidapi/latest/hidapi/)

`hidapi` 提供同步读写、超时读取和非阻塞读取模式，并非原生 async API。建议让设备工作线程持有句柄，通过消息通道接入 Runtime；不在异步调度线程里无限阻塞读取。这样仍可维护统一 Runtime，不要求所有底层库都返回 Future。[HidDevice API](https://docs.rs/hidapi/latest/hidapi/struct.HidDevice.html)

### BLE：现有功能覆盖足够，关键改动很新

`btleplug` 当前发行版 **0.13.0，docs.rs 记录为 2026-08-31**；changelog 的版本日期为 2026-08-29。它已有多年跨平台发行历史，覆盖 Linux BlueZ、macOS CoreBluetooth、Windows BLE。此处需要的是电脑作为 central 连接键盘，属于库的主要支持场景。[发行与平台说明](https://docs.rs/crate/btleplug/latest)

AhaKey 的 `7340` 服务、`7343` 命令、`7344` 通知、`7341` 数据，以及 `180A/2A25` 序列号读取，可以映射到服务发现、read、write、subscribe/notifications。这里没有发现需要另选串口库或通用 USB bulk 库的理由。[AhaKey 服务发现](https://github.com/AhakeyAI/desktop/blob/13240bb8d1ff92061eddf0a9b7d70c77d29e8b8d/ahakeyconfig-mac/Sources/Agent/AhaKeyAgent.swift#L1831)、[Peripheral API](https://docs.rs/btleplug/latest/btleplug/api/trait.Peripheral.html)

0.13 版本特别相关：新增无需扫描的设备检索；修正 macOS MTU 获取；改进 CoreBluetooth FIFO、无响应写入的背压、断连与迟到回调处理；修复 Windows 重复通知订阅。对 AhaKey 来说，这些正是最需要的能力。判断是“功能匹配度明显提高，但新修复尚缺本项目长期验证”，不能把已修问题继续描述成现版不支持，也不能由修复记录推导出 AhaKey 已稳定。[0.13 changelog](https://github.com/deviceplug/btleplug/blob/master/CHANGELOG.md#0130-2026-08-29)

### 三个需要重点验证的迁移点

**1. 系统已连接，但键盘不再广播。** 当前 Swift 主动调用 `retrieveConnectedPeripherals(withServices:)`，也通过已知 UUID 找回设备；只写 scan/connect 会丢掉这条恢复路径。0.13 的 `retrieve_peripherals` 已有对应入口，但返回设备不等于 AhaKey 服务、通知和协议协商全部 ready。[现有实现](https://github.com/AhakeyAI/desktop/blob/13240bb8d1ff92061eddf0a9b7d70c77d29e8b8d/ahakeyconfig-mac/Sources/Agent/AhaKeyAgent.swift#L1610)、[Central API](https://docs.rs/btleplug/latest/btleplug/api/trait.Central.html)

**2. OLED 写出成功与固件处理成功是两件事。** 当前代码按系统写入上限和固件上限共同分包，包间等待 12ms，并在发包前登记 `0x81` waiter，通过 session 判断结果。Rust 的 `.write().await` 不能替代这段协议。尤其需要核对 `mtu()` 与按写类型查询 `maximumWriteValueLength` 的差别，不能把 MTU 直接当作 AhaKey 数据长度。也不能未经测试就删除现有发送节奏。[现有上传](https://github.com/AhakeyAI/desktop/blob/13240bb8d1ff92061eddf0a9b7d70c77d29e8b8d/ahakeyconfig-mac/Sources/Agent/AhaKeyAgent.swift#L2953)、[write 接口语义](https://docs.rs/btleplug/latest/btleplug/api/trait.Peripheral.html#tymethod.write)

具体后端核对：调研时 CoreBluetooth 源码确实调用两种原生 retrieve 方法；其 MTU 在服务发现后由 `maximumWriteValueLengthForType(WithoutResponse) + 3` 得到；无响应写检查 `canSendWriteWithoutResponse` 后排队。这些支持采用判断，但不是 AhaKey 各固件的上传测试结果。实现细节来源是调研时的主分支，正式接入仍需固定发行依赖核对。[CoreBluetooth 后端源码](https://raw.githubusercontent.com/deviceplug/btleplug/master/src/corebluetooth/internal.rs)

**3. 重连后不要把旧通知当成新请求的回复。** 当前 Swift 在原生回调对象上绑定冻结的连接身份；Rust 公共通知流的语义不等于这个机制。文档明确通知 stream 可以跨连接持续有效，因此不能假设一次重连自动清空所有旧事件。这里需要检查后端回调归属并保留协议 session；仅给收到的事件贴上“当前代际”不能证明等价。[Swift 回调绑定](https://github.com/AhakeyAI/desktop/blob/13240bb8d1ff92061eddf0a9b7d70c77d29e8b8d/ahakeyconfig-mac/Sources/Agent/AhaKeyAgent.swift#L1918)、[notifications 语义](https://docs.rs/btleplug/latest/btleplug/api/trait.Peripheral.html#tymethod.notifications)

`bluest` 也是三平台 BLE 候选，提供已连接设备检索、已知设备打开等能力，但 Windows 的连接管理语义、Linux 对多线程 Tokio 的要求仍有差异。现有资料没有证明它对 AhaKey 更省维护，因此可作为同一硬件验证程序的备选，不能直接给出高于 btleplug 的成熟度结论。[Bluest 官方平台差异](https://github.com/alexmoon/bluest)

## 采用建议与验证范围

优先候选是 **Rust 共用协议和设备状态机 + hidapi USB 适配 + btleplug BLE 适配**。这是可以验证的实现方向，不是“换 Rust 后自动稳定”的承诺。一套 Runtime 可以共享绝大多数协议和业务逻辑，同时包含按系统编译的适配代码。

先用同一个小型连接程序验证：

1. 三个平台枚举正确设备，读取状态和序列号，持续接收拨杆变化。
2. Runtime 重启、电脑睡眠唤醒、蓝牙开关、键盘断电后，重新连接并订阅；覆盖系统已连接但无广播的情况。
3. 上传真实 OLED 资源，核对固件 ACK、包长和顺序；中途断开后恢复，不把旧 ACK 交给新会话。
4. USB 拔插、普通用户权限、多接口选择；保持键盘正常打字。
5. 长时间驻留观察资源占用、通知是否重复、任务是否积压；退出 Studio 后 Runtime 继续工作的部署验证另行进行。

这些是建议的验收场景，本次没有执行。若 BLE 回调归属无法满足现有语义，再考虑局部扩展 btleplug 后端或使用平台适配；目前不必预先维护三套完整 Runtime。

另外，Runtime 的电源保护使用 IOKit，并包含私有 `CGVirtualDisplay` 桥接；BLE/HID 库不会覆盖这部分。“硬件连接可共用”不代表所有系统功能无需平台代码。[PowerProtectionManager](https://github.com/AhakeyAI/desktop/blob/13240bb8d1ff92061eddf0a9b7d70c77d29e8b8d/ahakeyconfig-mac/Sources/Shared/PowerProtectionManager.swift)、[VirtualDisplay 桥](https://github.com/AhakeyAI/desktop/blob/13240bb8d1ff92061eddf0a9b7d70c77d29e8b8d/ahakeyconfig-mac/Sources/VirtualDisplayBridge/AhaKeyVirtualDisplay.m)
