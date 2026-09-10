# Xcode 开发方式

打开根目录 `AhaKey Studio.xcodeproj`，选择 **AhaKey Studio → My Mac**。`⌘R` 运行主应用，`⌘U` 运行应用与 VibeBar 的 16 个单元测试。完整 Xcode 16+ 可打开本工程；所有本地 Target（含两个测试 Target）均继承公共配置的 macOS 13.0 部署目标。当前 Xcode 26.4 自带 XCTest 的最低版本为 macOS 14，因此构建测试时会出现测试库版本不匹配的链接警告；设置为 13.0 不代表这套测试库可以在 macOS 13 上运行。在 macOS 13 实机运行测试时，需要使用支持该系统的 Xcode 与测试库。

## 文件组织

Apple 支持使用与磁盘对应的文件夹来组织工程，减少添加、移动源码时对工程文件的修改。本工程的源码和测试采用这种同步文件夹，并为各 Target 单独设置成员关系。`App`、`Features`、`Services` 是本项目的组织约定，Apple 没有强制使用这些目录名。[Apple：管理工程文件与文件夹](https://developer.apple.com/documentation/xcode/managing-files-and-folders-in-your-xcode-project)

```text
AhaKey Studio/
├── App/                 应用入口、AppDelegate、根视图
├── Features/            Studio、Device、Onboarding、Firmware、Voice、OLED、Account
├── Services/            Bluetooth、Agent
├── Assets.xcassets/     macOS App Icon 和 AccentColor
└── Resources/           Help、DefaultOLED、FirmwareFlasher
Modules/                 VibeBar、AhaKeyPluginKit 原生静态库
Tools/Agent/             正式应用内嵌的后台 Agent
Examples/                PluginCLI、PluginShowcase、VibeBarSmoke、SocketServer、SocketClient
Tests/                   AhaKeyStudioTests、VibeBarTests
AhaKey Studio.xcodeproj/  工程与构建设置、Info.plist、entitlements、构建输入清单
scripts/                 构建、发布、资源准备与 Socket 回归脚本
sdks/                    TypeScript 插件 SDK、示例和测试
docs/                    协议、开发与发布说明
```

往对应的源码文件夹添加 Swift 文件后，Xcode 自动将它纳入关联 Target。主 App 只链接实际使用的 VibeBar；AhaKeyPluginKit 由插件示例链接。DynamicNotchKit 保留在 Xcode Package Dependencies 中，由已提交的锁文件固定依赖解析结果。

示例有独立 Scheme，不加入正式 App 包。SocketServer 是 Foundation 命令行程序；SocketClient 保持原有 Client Target 名称。两个 Socket 示例共用 `/tmp/ahakey.sock`，使用前应停止占用该路径的后台 Agent。

## 构建设置

构建设置直接保存在 `AhaKey Studio.xcodeproj/project.pbxproj`，不再使用独立的 `Configuration` 目录或 `.xcconfig` 文件。在 Xcode 中点击蓝色工程图标，选择 PROJECT 或对应 TARGET 的 **Build Settings** 即可调整。

| 位置 | 内容 |
|---|---|
| PROJECT → Build Settings | 公共平台、macOS 13 部署目标、Swift 版本、开发 Team、版本与构建号 |
| PROJECT → Debug | 无优化、可测试性、当前架构、Debug 应用名称与标识后缀 |
| PROJECT → Release | 整模块优化、标准架构、dSYM、Release 应用后缀 |
| AhaKey Studio TARGET → Build Settings | App 产品名、Bundle ID、图标、Info.plist、entitlements 与 Hardened Runtime |

共享设置在 PROJECT 层修改，各 Target 继承，仅保留各自需要的覆盖值。需要直接编辑权限文件、应用信息或固件清单时，在 Finder 中右键 `AhaKey Studio.xcodeproj` → **显示包内容**。

| 配置 | 应用名 | Bundle ID |
|---|---|---|
| Debug | AhaKey Studio（调试） | com.xinyangzhang.AhaKey-Studio.debug |
| Release | AhaKey Studio | com.xinyangzhang.AhaKey-Studio |

源码仍使用 Swift 5 语言模式，不在这次整理中引入 Swift 6 并发语义变化。第三方包使用其自身声明的语言版本。所有本地可执行 Targets 启用 Hardened Runtime，静态库不单独签名。

本工程沿用 Developer ID / 公证的站外分发路线。主应用需要写入 IDE hook 配置、监听全局输入并启动辅助程序，因此保留 `ENABLE_APP_SANDBOX = NO`；Hardened Runtime 与 App Sandbox 是不同机制，启用前者不代表启用了后者。若以后要上架 Mac App Store，需要另行设计这些能力的沙盒访问方式。[Apple：站外分发](https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html)、[App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)

## 元数据、权限与资源

Xcode 自动生成标准 Bundle 元数据；`AhaKey Studio.xcodeproj/Info.plist` 只保留应用名称、类别与权限用途描述。`AhaKey Studio.xcodeproj/AhaKeyStudio.entitlements` 声明蓝牙和音频输入权限。

申请麦克风和语音识别权限时使用系统 API。用户已拒绝时打开系统设置；App 不再调用 `sudo` / `tccutil` 重置权限，也不在运行时重签自身。Apple 将 `tccutil` 描述为开发时从 Terminal 调试授权提示的工具。[Apple：macOS 媒体授权](https://developer.apple.com/documentation/bundleresources/requesting-authorization-for-media-capture-on-macos)

Help 与 DefaultOLED 作为文件夹资源保留层级。FirmwareFlasher 的 SHA-256 校验脚本在沙盒内运行，输入列在 `AhaKey Studio.xcodeproj/FirmwareInputs.xcfilelist`，只写入一个构建校验标记。文件复制和工具签名交给 Xcode 原生 Copy Files / Code Sign On Copy；Release 的签名参数也为这些预编译工具启用 runtime。修改或增加固件资源时同步更新校验清单、输入文件清单和对应 Copy Files 阶段。[Apple：构建脚本的输入和输出](https://developer.apple.com/documentation/xcode/running-custom-scripts-during-a-build)

Agent 由 Copy Files 构建阶段嵌入 `Contents/MacOS/ahakeyconfig-agent`，使用 Code Sign On Copy。应用可执行文件名保持 `AhaKeyConfig`，便于兼容现有后台管理逻辑。

公共配置设置 `COPY_PHASE_STRIP = NO`，避免在复制已签名的 Agent 和 Xcode 测试库时尝试剔除符号。它仅控制复制阶段，链接时的无用代码剔除和归档时产品自身的符号剔除仍由各自设置控制。[Apple：构建设置参考](https://developer.apple.com/documentation/xcode/build-settings-reference)

## 命令行

```bash
make debug
make build
make test

# 无开发证书的本地验证
SIGNING_IDENTITY=- make debug

# 单独运行示例
./scripts/run-target.sh PluginShowcase
./scripts/run-target.sh VibeBarSmoke
./scripts/run-target.sh SocketServer
./scripts/run-target.sh Client
```

构建脚本从 Xcode 读取实际产品路径，将完整 App 复制到 `dist/`。版本、产品名、部署目标默认取自 Xcode 工程设置；`APP_VERSION`、`APP_BUILD`、`BUILD_ARCHS`、`MACOS_DEPLOYMENT_TARGET`、`APP_BUNDLE_NAME`、`APP_DISPLAY_NAME` 仅在显式设置时覆盖。可用 `SIGNING_IDENTITY` 指定证书，用 `OUTPUT_DIR` / `DERIVED_DATA_PATH` 改变产物位置。

`Product → Archive` 生成 Xcode 归档；`scripts/pack-release.sh` 保留 Developer ID 签名与公证的发布流程。CI 编译示例、执行单元测试和 SDK 测试，再构建通用架构 App。

原有 `scripts/test-unix-client.py` 在本机关闭连接时存在 `Network.NWError 50` 导致退出码断言失败的情况，迁移前也可复现；因此它仍是单独运行的诊断脚本，不列入 CI 必跑步骤。
