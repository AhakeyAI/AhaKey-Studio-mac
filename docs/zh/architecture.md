# Architecture

[English](../architecture.md) · **简体中文** · [日本語](../ja/architecture.md)

> 分支范围：本文描述 [`dev`](https://github.com/AhakeyAI/AhaKey-Studio-mac/tree/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c) 上的 Studio/Rust 实现。本次 `main` 只接收文档；前端命令需在该实现的检出目录运行，相关源码、fixtures 和构建目标不包含在此文档分支中。

本仓库是 macOS Studio 的 Xcode 工程。旧文档中的 Windows、Linux、BLE TCP bridge 和根目录 `Package.swift` 属于此前的 Desktop monorepo，不在当前仓库。

## 两个应用入口

`AhaKey Studio` 是迁移前的完整 Swift 客户端，包含设备配置、语音、账号、刷机，以及 `Tools/Agent` 中的后台 daemon 和 Hook CLI。它仍通过 Swift CoreBluetooth 管理硬件，Studio 与 daemon 之间保留旧的连接 owner 切换。

`Studio Frontend` 是面向独立 Rust Runtime 的新 SwiftUI 客户端。它的 source target 不包含 BLE、旧 Agent、固件命令编码或刷机执行器。开发者可通过 `Studio Frontend Mock` scheme 无设备运行；真实模式使用本机 WebSocket + JSON-RPC，协议见 [当前接口子集](../../contracts/runtime-v1/README.zh-CN.md)。Rust 实现在独立仓库，尚未完成联调。

```text
Studio Frontend → StudioModel → RuntimeClient → 本机 IPC → Rust Runtime → 键盘
                      ├─ StudioDraftStore：用户草稿
                      └─ RuntimeStore：后台状态与操作结果
                                   └─ RuntimeVibeBarBridge → VibeBar
```

Rust Runtime 的目标职责是唯一持有设备连接，执行配置、资源上传、Hook 和刷机。Studio 退出只关闭自己的连接，不终止 Runtime。当前 Mock/fixture 不代表这些后台能力已实现。

## 代码目录

| 目录 | 作用 |
|---|---|
| `StudioFrontend/` | 新应用入口、页面、草稿与后台状态、IPC 和 Mock |
| `AhaKey Studio/App`、`Features`、`Services` | 旧应用入口与完整功能实现；少量纯模型和账号实现被新 target 显式复用 |
| `AhaKey Studio/SharedPresentation` | 共用键盘画布、快捷键编辑器、GIF 预览、账号页面与显示模型 |
| `Modules/VibeBar` | 共用的 macOS 浮层 UI |
| `Modules/AhaKeyPluginKit`、`sdks/typescript` | 现有插件宿主与 stdio JSON-RPC SDK，尚不是 Runtime SDK |
| `Tools/Agent` | 旧 Swift daemon 与工具 Hook CLI |
| `contracts/runtime-v1` | 当前新前端的协议 Schema 和 fixtures |
| `Tests/StudioFrontendTests` | 前端状态、操作恢复、真实 WebSocket fixture 联调 |

## 状态与执行约束

- Studio 草稿与 Runtime 权威状态分开保存；选中编辑模式不自动切换设备实际模式。
- 前端提交配置意图，不组装 BLE 字节、Flash 地址或设备写入序列。
- 快照与事件用于恢复状态；请求 id 只配对当前连接的响应，operationId 用于跨连接查询操作。
- 配置基线过期时阻止保存；未知状态不以默认电量或自动批准状态代替。
- Rust 接管真机前必须停止旧 BLE owner。新前端不会在 IPC 失败时自动启用旧蓝牙实现。
- macOS 语音、输入注入及权限属于执行它们的进程；新前端当前未启动这些能力。

具体运行方式、数据迁移和当前限制见 [独立前端开发说明](studio-frontend.md)，完整迁移路线见 [拆分方案](studio-frontend-extraction.md)。云端账号服务和 Rust 后台均不在本仓库实现。
