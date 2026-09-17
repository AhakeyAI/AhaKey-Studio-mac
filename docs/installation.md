# 安装与开发

当前仓库提供 macOS 13 及以上的 AhaKey Studio，Release 应用同时包含 Apple Silicon 和 Intel 架构。

## 安装

在 [GitHub Releases](https://github.com/ZephyrKeXiner/AhaKey-Studio/releases) 下载已发布的 `AhaKey-Studio-macOS.dmg`，打开后把应用拖到 Applications。若尚无 Release，需要维护者先完成一次签名、公证发布。

GitHub Actions 的开发 ZIP 用于构建验证，未经公证，不作为正式安装包分发。源码仓库不保存生成的 `.app`、`.dmg` 或签名私钥。

## 在 Xcode 中开发

1. 安装完整 Xcode；CI 固定使用 Xcode 16.4。
2. 打开根目录的 `AhaKey Studio.xcodeproj`。
3. 在 Signing & Capabilities 中选择自己的开发 Team。
4. 选择 **AhaKey Studio → My Mac**，按 `⌘R` 运行，按 `⌘U` 测试。
5. 示例通过 `Plugin`、`PluginShowcase` 或 `VibeBarSmoke` Scheme 运行。主应用已内嵌后台 Agent。

测试部署目标为 macOS 13；较新的 Xcode 若自带最低版本为 macOS 14 的 XCTest，可能产生测试库版本警告。在 macOS 13 实机测试需要兼容的 Xcode 和测试库。

本地开发不需要构建 Shell 脚本或 Makefile。构建设置、资源复制和签名均在 Xcode 工程中维护，详见 [Xcode 开发方式](xcode-development.md)。

## TypeScript SDK

在 `sdks/typescript` 中运行 `npm ci`、`npm run typecheck` 和 `npm test`。示例先执行 `npm run build`，再通过 Xcode Scheme 启动 Swift 宿主。详见 [SDK 指南](zh/typescript-sdk.md)。

## 自动构建与发布

每次分支推送和 Pull Request 自动运行 CI；版本标签触发通过测试后签名、公证、发布 DMG 的流程。凭据配置和操作步骤见 [GitHub CI/CD](release-distribution.md)。
