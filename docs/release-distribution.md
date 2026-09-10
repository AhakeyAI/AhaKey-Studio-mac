# GitHub CI/CD 与 macOS 发布

构建逻辑集中在两份 GitHub Actions 工作流，日常开发直接使用 Xcode。仓库不再维护本地构建、打包、公证的 Shell 脚本。

## CI：每次提交与 Pull Request

[ci.yml](../.github/workflows/ci.yml) 在分支推送、Pull Request 或 Actions 页面手动运行时执行，也供发布流程复用：

1. 使用 macOS 15 runner 与 Xcode 16.4，运行应用和 VibeBar 的 16 项测试。
2. 编译插件、状态栏和 Socket 示例。
3. 编译 Apple Silicon + Intel 通用 Release 应用，检查签名和两个架构。
4. 上传测试报告及开发用 ZIP。
5. 在 Linux runner 上使用 Node.js 22 验证 TypeScript SDK。

`AhaKey-Studio-development` 是临时签名、未经公证的开发产物，用于验证构建；正式下载使用 GitHub Releases 的 DMG。应用部署目标仍为 macOS 13。

## CD：发布版本标签

[release.yml](../.github/workflows/release.yml) 在推送 `v*` 标签时触发。先复用完整 CI；所有检查成功后，才进入持有签名凭据的发布任务。

发布任务依次执行：导入证书 → Xcode Archive → 原生工具生成 DMG → 签名 → Apple 公证 → 附加并校验公证票据 → 上传 GitHub Release。DMG 中包含应用和 Applications 快捷方式，使用标准 Finder 布局，不依赖图形界面自动化。

支持 `v0.2.1` 或 `v0.2.1-beta.1` 这样的标签。带预发布后缀的标签生成 GitHub prerelease。应用版本取标签中的三段数字，构建号取 GitHub run number。不要复用已经发布的标签。

## 配置 GitHub Secrets

在当前仓库的 **Settings → Secrets and variables → Actions → New repository secret** 中配置：

| Secret | 内容 |
|---|---|
| `MACOS_CERTIFICATE_P12_BASE64` | 包含私钥的 Developer ID Application 证书 `.p12`，转为 Base64 |
| `MACOS_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的密码 |
| `APPLE_ID` | 有该开发团队权限的 Apple ID |
| `APPLE_TEAM_ID` | Developer ID 证书所属团队 ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | 该 Apple ID 的应用专用密码 |

本机可用 `base64 -i /path/to/certificate.p12 | pbcopy` 准备证书 Secret。凭据不要提交到仓库，也不要放入 Issue、日志或聊天。普通 CI 不需要这些 Secrets；缺少凭据时发布任务会报错，不会生成未公证的正式 Release。

证书仅导入 GitHub 托管 runner 的临时钥匙串，任务结束时清理。[GitHub：在 macOS runner 安装 Apple 证书](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)

## 发布操作

确认目标提交的 CI 通过后，在 GitHub 创建并推送一个新的版本标签，或在本机执行以下命令（版本号仅为示例）：

```bash
git tag v0.2.1
git push origin v0.2.1
```

工作流成功后，[Releases](https://github.com/ZephyrKeXiner/AhaKey-Studio/releases) 中会出现：

- `AhaKey-Studio-macOS.dmg`：通用架构、已签名并公证的安装包。
- `SHA256SUMS`：最终 DMG 的校验值。

公证状态记录会保存在工作流的 `notarization-result` artifact。公证必须返回 `Accepted`，并通过票据和系统校验后才发布；如失败，先根据记录中的 submission ID 查询 Apple 公证日志。签名、公证和真机键盘体验仍需在首次正式发布时验收。[Apple：自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)

## 本地开发

打开 `AhaKey Studio.xcodeproj`，选择 **AhaKey Studio → My Mac**，使用 `⌘R` 运行、`⌘U` 测试；本地归档用 **Product → Archive**。详见 [Xcode 开发方式](xcode-development.md)。
