# 独立 Studio 前端开发

[English](../studio-frontend.md) · **简体中文** · [日本語](../ja/studio-frontend.md)

> 分支范围：本文描述 [`dev`](https://github.com/AhakeyAI/AhaKey-Studio-mac/tree/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c) 上的 Studio/Rust 实现。本次 `main` 只接收文档；前端命令需在该实现的检出目录运行，相关源码、fixtures 和构建目标不包含在此文档分支中。

`dev` 从 `origin/main` 的 `2f77109` 创建。本次落实前端拆分的第一阶段；保留旧版作为迁移基线，Rust 仓库没有被修改。

Rust 后端开发者从 [Rust Runtime 对接 Studio 开发文档](rust-backend-integration.md) 开始，包含服务配置、完整接口语义、首次初始化约束和联调验收。

## 运行

用 Xcode 打开 `AhaKey Studio.xcodeproj`：

- **Studio Frontend Mock**：无需设备或后台，可编辑四个模式的键位、宏、灯效、全局亮度和本地 GIF。顶部明确标识 MOCK，菜单可模拟断线、受理响应丢失、部分写入失败和外部修改。
- **Studio Frontend**：真实 IPC 客户端。读取当前用户的 Runtime discovery 文件；后台不存在时可以继续编辑草稿，自动重试连接，不会启动旧 Agent 或回退到 Swift BLE。
- **AhaKey Studio**：原有完整客户端；仍有 Swift 后台与蓝牙实现，用于迁移期间对照。真实设备交给 Rust 前必须停止旧设备 owner。

命令行验证：

```sh
python3 scripts/check-frontend-boundary.py
python3 scripts/check-localizations.py
xcodebuild -project "AhaKey Studio.xcodeproj" -scheme "Studio Frontend" \
  -configuration Debug -destination "platform=macOS,arch=arm64" \
  -derivedDataPath DerivedData/Frontend \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual test
```

Intel Mac 将 arch 改为 x86_64。Mock scheme 传入 `--mock-runtime`；直接运行构建产物时也可传此参数。

## 代码分工

| 位置 | 职责 |
|---|---|
| `StudioFrontend/App` | 独立 App 生命周期，Runtime 到 VibeBar 的状态投影 |
| `StudioFrontend/Views` | 页面布局和编辑交互，无硬件调用 |
| `StudioFrontend/State/StudioDraftStore.swift` | 草稿持久化、全局亮度、草稿到业务配置转换 |
| `StudioFrontend/State/RuntimeStore.swift` | 快照与事件投影、序号和订阅隔离、外部修改失效标记 |
| `StudioFrontend/State/StudioModel.swift` | 连接恢复、配置基线、持久化未决操作和结果查询 |
| `StudioFrontend/Runtime` | DTO、业务接口、内存 Mock、真实 WebSocket adapter |
| `AhaKey Studio/SharedPresentation` | 两个 target 共用的键盘画布、快捷键编辑器、GIF 预览、账号页面、HID 显示和 IDE 状态 |
| `AhaKey Studio/Services/Bluetooth/LegacyDraftEncoding.swift` | 仅旧 target 使用的固件灯效和宏字节编码 |
| `contracts/runtime-v1` | 当前前端消费的协议子集、JSON Schema 和固定样例 |

新 target 的构建依赖只有 VibeBar；没有旧 Agent、CoreBluetooth、OLED 设备编码或刷机程序。共用代码显式加入新 target，避免把整个旧源码根自动加入编译。CI 运行源码依赖检查和独立前端测试。

## 状态与数据

本地编辑模式与设备实际模式分开；切换标签不会修改键盘工作模式。选中 GIF 或修改灯效只更新草稿与本地预览；只有保存配置才提交后台请求。

Mock 和真实模式使用不同的 UserDefaults domain：`ai.ahakey.studio.frontend.mock` 与 `ai.ahakey.studio.frontend`。真实模式首次启动只读复制旧版的 `ahakey.studio.draft.v1`；Debug 优先旧 `.debug` domain，Release 使用旧正式版 domain。旧版偏好不会被改写。亮度从旧 Mode 0 提取为设备级字段。已有新草稿不会被后续旧版数据覆盖。

新导入的 GIF 复制到 `~/Library/Application Support/AhaKey/StudioFrontend/Assets`，不会发送本地路径给 Runtime。旧草稿中的自选素材路径仍保留；若原文件已不存在，需要重新选择。当前没有迁移旧模式昵称、Hook 策略或语音路由，它们仍由旧版管理。

后台状态不覆盖草稿。外部配置变化会阻止保存，用户可核对后重新读取基线；该操作保留草稿，下一次保存明确覆盖选中范围。保存期间继续编辑时，完成事件只更新后台基线，不把后续编辑误标为已保存。

发送前记录 operationId 与原请求。断线或丢失响应时查询原操作，绝不自动重发配置。部分失败清除可写基线；历史操作查不到时保留“结果未知”，需要用户核对设备。退出 Studio 只关闭客户端连接，不向 Runtime 发送停止/取消操作。

## 当前范围

已接通内存 Mock 与独立 Python WebSocket fixture。测试覆盖真实 WebSocket 传输及消息解析，但尚未与 Rust Runtime 或真机联调。Rust 需要按 [当前协议子集](../../contracts/runtime-v1/README.zh-CN.md) 实现接口。

当前配置保存只包括键位、灯效和全局亮度。OLED 上传、物理灯效预览、Hook 管理、语音监听、文本注入和固件刷写留待后续 Runtime 功能接入，界面会明确说明。账号页面复用现有云端实现。前端不会请求蓝牙、录音或输入监控权限。

当前只展示快照中的第一台设备，没有主动扫描与多设备选择；未知电量和拨杆显示为未知。后续完成 Rust 的连接/状态/配置闭环后，再逐步迁移完整后台能力，最后替换旧发行 target。
