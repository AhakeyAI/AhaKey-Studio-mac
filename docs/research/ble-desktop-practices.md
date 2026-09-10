# AhaKey 可参考的非 Swift BLE 实践

调研日期：2026-09-08。范围为公开源码、发行说明与官方文档；未运行这些软件或实测 AhaKey。

## 结论

已有实际发布的软件用 C++、Rust、Python 管理 BLE。跨平台库主要统一接口：在 macOS 上仍接入 CoreBluetooth，Windows 使用系统蓝牙接口，Linux 通常使用 BlueZ。换语言能复用应用逻辑，但无法消除操作系统、设备固件和连接生命周期差异。[Qt 平台说明](https://doc.qt.io/qt-6/qtbluetooth-index.html)、[Bleak 后端说明](https://bleak.readthedocs.io/en/latest/backends/)

## 三个案例

| 软件 | 已核实实现 | 对 AhaKey 的参考价值 |
| --- | --- | --- |
| GoldenCheetah | C++ + Qt Bluetooth，连接心率、功率传感器和骑行台；发布 Windows、macOS、Linux 安装包 | 可参考直接控制硬件的三平台桌面软件 |
| Intiface Central / Engine | Flutter 界面，Rust Buttplug / Intiface Engine 管理硬件，BLE 后端为 btleplug；提供三平台桌面版本和 WebSocket 客户端接入 | 最接近“界面与共用硬件 Runtime 分离”的参考 |
| Home Assistant | Bluetooth 集成使用 Python Bleak，并发布明确的连接最佳实践 | 适合参考长期驻留服务的扫描和重连；不是三平台原生桌面部署的证明 |

来源：[GoldenCheetah 项目](https://github.com/GoldenCheetah/GoldenCheetah)、[发行记录](https://github.com/GoldenCheetah/GoldenCheetah/releases)、[Intiface 下载及集成说明](https://intiface.com/)、[Buttplug 架构](https://github.com/buttplugio/buttplug)、[Home Assistant 开发文档](https://developers.home-assistant.io/docs/bluetooth/)。

### GoldenCheetah：连接生命周期仍由应用管理

`BT40Device.cpp` 使用 `QLowEnergyController::createCentral`，连接成功后发现服务，再注册特征变化等回调。意外断连时停止控制输出并重连；用户主动断开则停止重试。当前源码先立即重试，再由 5 秒定时器驱动。这个间隔是其实现选择，不能当作所有 BLE 设备的统一最佳值。[源码](https://github.com/GoldenCheetah/GoldenCheetah/blob/master/src/Train/BT40Device.cpp)

### Intiface：Rust BLE 确有产品使用，但要区分进程结构

Central 是 Flutter 界面，内嵌 Rust 引擎；Engine 也能作为独立命令行程序提供服务。外部应用通过 WebSocket 等协议接入硬件服务。因此它能证明 Rust 与 btleplug 的实际产品使用，并提供界面与硬件职责分离的案例，但不能画成“Central 自己的 Flutter 界面必然通过 IPC 调用独立后台进程”。[Central 源码说明](https://github.com/intiface/intiface-central)、[Engine 所在仓库](https://github.com/buttplugio/buttplug)、[BLE 硬件管理模块](https://github.com/buttplugio/buttplug/tree/master/crates/buttplug_server_hwmgr_btleplug)

其发行记录仍有断连后无法重连、蓝牙错误洪泛阻塞设备命令等修复。产品使用说明路径可行，不意味着换库后无需处理恢复和错误隔离。[发行记录](https://github.com/intiface/intiface-central/releases)

### Home Assistant：有明确的官方最佳实践

官方建议共享扫描器，避免每个集成重复扫描；Bleak 每次建立新连接使用新 Client；BlueZ 首次解析服务时至少预留 10 秒连接超时，并使用重试连接器处理暂时失败。这里的“新连接”指断开后的下一次连接，并非每发送一条命令就重连；这些具体规则属于 Bleak / Home Assistant 环境，不能机械套给 btleplug。[官方最佳实践](https://developers.home-assistant.io/docs/bluetooth/)

## 对 AhaKey 的应用判断

建议把扫描、连接、订阅和恢复交给唯一的 Runtime 管理，Studio 发送业务命令。在一个连接会话内持久收发；断开后重新建立可用会话。连接成功、服务发现完成、通知订阅完成、AhaKey 协议握手完成应分别处理；业务层就绪后再允许配置写入。Qt 官方流程也是连接后发现服务和特征，再读写或订阅。[Qt BLE 流程](https://doc.qt.io/qt-6/qtbluetooth-le-overview.html)

以上是基于案例作出的设计建议。它们不替代 AhaKey 的 OLED 分包、设备 ACK、睡眠唤醒及系统已连接但停止广播等实机验证；也不能单独证明 Rust 比 C++ 或当前 Swift 实现更稳定。
