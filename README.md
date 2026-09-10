# AhaKey Studio

原生 macOS 键盘配置应用，包含蓝牙连接、OLED 管理、固件烧录、语音输入、VibeBar 与后台 Agent。

打开 **AhaKey Studio.xcodeproj**，选择 **AhaKey Studio → My Mac**。按 **⌘R** 运行，**⌘U** 测试。

```bash
make debug    # Debug App → dist/
make build    # 通用架构 Release App → dist/
make test     # 应用与 VibeBar 单元测试
```

源码位于 `AhaKey Studio/App`、`Features` 和 `Services`；公共库在 `Modules`，测试在 `Tests`，共享设置在 `Configuration`。`Examples` 中的插件和 Socket 示例使用各自 Scheme，不进入主应用。

- [文件组织、构建设置与权限](docs/xcode-development.md)
- [签名与发布](docs/release-distribution.md)
- [插件 SDK](sdks/README.md)
- [BLE 协议](docs/ble-protocol.md)
- [Runtime / Studio 协议](docs/runtime-studio-protocol-v1.md)
