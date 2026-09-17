# 本地化（i18n）

Studio 支持简体中文（`zh-Hans`）和英文（`en`），使用 Apple String Catalog，最低系统版本仍为 macOS 13。日语尚未发布；实现和验证支持后续增加 `ja`。

## 切换语言

默认跟随 macOS 首选语言。也可以在「系统设置 → 通用 → 语言与地区 → 应用程序」添加 AhaKey Studio，选择语言，然后退出并重新打开 App。

开发时，在 Xcode 的 Product → Scheme → Edit Scheme → Run → Options 中设置 App Language。不要仅靠 SwiftUI Preview 的 locale 环境测试普通 String：服务层文案通过 Bundle 的语言在创建时解析，需用相应语言重新启动应用。

不支持运行中即时切换。没有匹配翻译时，由 Bundle 根据用户首选语言和开发语言简体中文选择回退。OLED 显示状态不写入配置，启动时以当前语言重建；素材路径、FPS 和用户自定义内容继续保存。

## 资源和调用

- `AhaKey Studio/Localization/Localizable.xcstrings`：界面、帮助中心、服务状态、错误提示，以及主应用使用的 VibeBar 文案。
- `AhaKey Studio/Localization/InfoPlist.xcstrings`：系统蓝牙、麦克风、语音识别权限用途说明。
- `String(localized:defaultValue:)`：同时覆盖 SwiftUI、AppKit 和普通 String 属性，避免把动态 String 传给 Text 时绕过本地化。
- Localization 目录由主 Target 的同步目录自动纳入资源构建；不要放到被排除的 Resources 目录里。
- VibeBar 是静态模块，使用主应用 Bundle 的翻译，独立示例没有宿主翻译时使用英文 defaultValue。

现有 `text.*` 键是稳定资源标识，原文和所属文件记录在 Catalog 注释中。修改文案时保留键；新增条目优先使用含义明确的键，例如 `device.lighting.off`。相同中文、不同语义必须拆键：窗口“关闭”是 Close，灯光“关闭”是 Off。修改文案时同步 defaultValue、所有已发布翻译和上下文注释。

动态内容作为插值参数，翻译整个句子，不拼接多个已翻译片段来决定词序。数量使用原始 `Int` 插值（`%lld`），通过 Xcode 的 **Vary by Plural** 设置复数；多参数使用明确的 substitution `argNum`，不要让编译器猜测。中文和日语通常只需 `other`，英文需 `one` / `other`。新增语言按 Xcode 提供的语言规则填写，不照搬英文复数分类。当前已覆盖帧数、动画数、宏步骤数和移除子命令数。

字符串和已精确格式化的协议值使用 `%@`。翻译可用 `%2$@`、`%1$lld` 调换顺序，但必须保持参数索引及类型，不能把 `%lld` 改成 `%@`。格式化文案里的字面百分号使用 `%%`。货币显示使用固定 CNY 币种和系统地区格式，协议数值与十六进制标识保持精确。

## 保持稳定的内容

配置与协议字段、Codable rawValue、UserDefaults 键、文件路径、设备 LCD 的 ASCII 按键描述及用户自定义名称不翻译。旧中文配置值仅用于兼容迁移识别。设备写入成功、拨杆颜色/位置、语音路由是否存在均按状态判断，不比较翻译文本。

开发诊断原始日志、外部工具输出、服务器返回的错误文字、第三方 CLI 补丁及插件自带文案保留原内容；不会自动翻译用户数据或服务器消息。

## 增加日语

1. 在 Xcode 项目的 Info → Localizations 添加 Japanese (`ja`)，并在两个 String Catalog 中补齐日语。完成前不要把空的日语资源作为正式支持语言发布。
2. 翻译全部正文、错误、帮助和三项系统权限用途说明；保留品牌名与用户数据。根据 Catalog 注释核对每个参数、按钮动作和设备状态的语义。
3. 日语可按自然词序调整位置参数；复数采用该语言需要的分类。无需增加 `if language == "ja"` 之类业务分支，也无需修改 CI 语言列表。
4. 运行下述验证，再以日语启动检查引导、Studio 编辑器、帮助、错误和 VibeBar。检查固定宽度、换行、截断以及数字/货币/日期；以日本地区再检查一次格式。
5. 由熟悉产品的日语使用者校对术语和自然度。自动测试验证资源完整性与运行行为，不能代替语言质量审核。

建议术语约定（正式日译前仍需校对）：

| 概念 | 简体中文 | English | 日语候选 / 注意事项 |
|---|---|---|---|
| 关闭窗口动作 | 关闭 | Close | 閉じる |
| 灯光状态 | 关闭 | Off | オフ / 消灯，勿与关闭窗口混用 |
| 审批开关 | 拨杆 | Switch | スイッチ |
| 审批方式 | 自动 / 手动 | Auto / Manual | 自動 / 手動 |
| 图片帧 | 帧 | frame / frames | フレーム，无英文式单复数 |
| 工作模式 | 模式 | Mode | モード，保持固件编号不变 |
| 集成机制 | Hooks | Hooks | 保留 Hooks，并根据上下文解释 |

## 验证

```sh
python3 -m unittest discover -s Tests -p '*Tests.py'
python3 scripts/check-localizations.py

xcodebuild -project "AhaKey Studio.xcodeproj" -scheme "AhaKey Studio" \
  -destination 'platform=macOS' -testLanguage en \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual test

xcodebuild -project "AhaKey Studio.xcodeproj" -scheme "AhaKey Studio" \
  -destination 'platform=macOS' -testLanguage zh-Hans \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual test
```

`check-localizations.py` 从工程发现已发布语言，检查两个 Catalog 的语言覆盖、翻译完成状态、非空文本、插值参数位置/类型，以及 Swift 显式本地化键是否存在。支持参数换序、重复参数和复数 substitutions，不要求译文保持中文词序。

`LocalizationTests` 从实际 App 包发现全部语言，验证 `.strings` 与 `.stringsdict` 的键集合、权限说明、数量 0/1/2/70 的输出和插值。独立的临时日语测试资源验证“other-only 复数 + 参数换序”，不会随 App 发布。`OLEDLocalizationTests` 验证旧配置跨语言读取、用户数据保真及状态变化不会触发硬件配置变更。

GitHub CI 先验证资源，再运行英文完整测试和其余已发布语言的本地化测试。未来添加完整的 `ja` 后会自动纳入检查；不需要额外 shell 脚本。新增界面仍需检查文字较长时的布局，让说明自然换行，避免按单一语言的长度设置截断。

Apple 参考：[String Catalog 与复数](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog)、[复数规则](https://developer.apple.com/documentation/xcode/localizing-strings-that-contain-plurals)。
