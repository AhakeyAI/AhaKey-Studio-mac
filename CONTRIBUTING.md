# 开发检查

打开根目录 `AhaKey Studio.xcodeproj`。项目导航中的同步文件夹与磁盘一致，新增 Swift 文件放入对应 Target 的目录即可。业务代码按 `App`、`Features`、`Services` 组织，公共模块、示例、测试分别在 `Modules`、`Examples`、`Tests`。

- 主应用与公共模块：`make test`，并构建相关 Scheme。
- Socket 示例：`python3 scripts/test-unix-client.py`，当前本机已知的关闭连接问题见开发说明。
- TypeScript SDK：在 `sdks/typescript/` 执行 `npm ci`、`npm run typecheck` 和 `npm test`。
- 发布产物：`./scripts/package_app.sh` 构建本地签名的通用架构 App。

共享设置在 Xcode 的 PROJECT → Build Settings 中修改，避免在各 Target 中重复覆盖。配置直接保存在 `AhaKey Studio.xcodeproj/project.pbxproj`。添加固件资源时同时更新 SHA-256 清单与 `AhaKey Studio.xcodeproj/FirmwareInputs.xcfilelist`。不要提交构建产物、node_modules、签名证书或个人设置。详见 [Xcode 开发方式](docs/xcode-development.md)。
