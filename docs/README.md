# Documentation · 文档 · ドキュメント

[English home](../README.md) · [中文首页](zh/README.md) · [日本語ホーム](ja/README.md)

The Studio/Rust developer documentation below is available in all three languages. Other existing guides retain their current language; this index does not imply the entire repository has been translated.

以下 Studio/Rust 开发文档提供中英日完整版本。其他既有指南保留原语言，并非整个仓库的文档都已翻译。

以下の Studio/Rust 開発文書には中英日の完全版があります。他の既存ガイドは元の言語を維持しており、リポジトリ全体が翻訳済みという意味ではありません。

| Topic / 主题 / 項目 | English | 简体中文 | 日本語 |
|---|---|---|---|
| Architecture / 架构 / アーキテクチャ | [English](architecture.md) | [中文](zh/architecture.md) | [日本語](ja/architecture.md) |
| Frontend development / 前端开发 / フロントエンド開発 | [English](studio-frontend.md) | [中文](zh/studio-frontend.md) | [日本語](ja/studio-frontend.md) |
| Extraction plan / 拆分方案 / 分離計画 | [English](studio-frontend-extraction.md) | [中文](zh/studio-frontend-extraction.md) | [日本語](ja/studio-frontend-extraction.md) |
| Rust integration / Rust 对接 / Rust 接続 | [English](rust-backend-integration.md) | [中文](zh/rust-backend-integration.md) | [日本語](ja/rust-backend-integration.md) |
| Runtime contract / Runtime 协议 / Runtime プロトコル | [English](../contracts/runtime-v1/README.md) | [中文](../contracts/runtime-v1/README.zh-CN.md) | [日本語](../contracts/runtime-v1/README.ja.md) |

## Maintenance · 维护约定 · 保守方針

- Update all three versions when changing interface semantics, limits, or setup steps. Keep the distinction between implemented behavior and future plans in every language.
- 接口语义、限制或运行步骤变更时，同步三种语言；各版本都必须区分已实现行为和后续规划。
- インターフェースの意味、制限、起動手順を変更するときは三言語を同時に更新し、実装済みの動作と将来計画を区別してください。

Keep wire keys, method/error names, paths, environment variables, numbers, JSON examples, and executable shell commands unchanged. Translate explanatory prose and diagram annotations. JSON Schema and fixtures are shared under `contracts/runtime-v1` on the documented `dev` implementation; this documentation branch links to them instead of copying implementation assets.

协议键、方法和错误码、路径、环境变量、数值、JSON 示例和可执行 shell 命令保持一致；翻译说明正文与示意图注释。JSON Schema 和 fixtures 位于本文所述 `dev` 实现的 `contracts/runtime-v1`；此文档分支通过链接引用，不复制实现资源或另建翻译副本。

通信キー、メソッド/エラー名、パス、環境変数、数値、JSON サンプル、実行用 shell コマンドは変更せず、説明と図の注釈を翻訳します。JSON Schema と fixture は対象の dev 実装の `contracts/runtime-v1` を共有します。この文書ブランチではリンクで参照し、実装資源や翻訳コピーを追加しません。

Check relative links from each translated file's directory. Language switches must open the same document, and topic links should use the reader's language when a translation exists. Check JSON parsing, command/example equality, and corresponding section coverage before submitting. Application String Catalog checks do not validate Markdown documentation.

相对链接按译文所在目录解析。语言切换应打开同一篇文档，主题链接优先使用同语言版本。提交前检查 JSON 语法、命令和示例一致性以及章节覆盖；应用 String Catalog 检查不验证 Markdown 文档。

相対リンクは翻訳ファイルのディレクトリを基準に確認します。言語切り替えは同じ文書を開き、本文リンクも翻訳があれば同じ言語へ向けます。提出前に JSON 構文、コマンド・例の一致、対応する節を確認してください。アプリの String Catalog 検証は Markdown 文書を検証しません。
