<div align="center">

# ⌨️ AhaKey Desktop

**AhaKey-X1 — Vibecoding Keyboard の macOS コンパニオンアプリ。**

[**English**](../../README.md) &nbsp;·&nbsp; [**简体中文**](../zh/README.md) &nbsp;·&nbsp; [**日本語**](README.md)

[**ドキュメント**](#documentation) &nbsp;·&nbsp; [**SDK**](../../sdks/README.md) &nbsp;·&nbsp; [**⭐ Star 履歴**](#star-history) &nbsp;·&nbsp; [**🤝 コントリビュート**](#contributing)

<br/>

<a href="https://github.com/ZephyrKeXiner/AhaKey-Studio/releases"><img src="https://img.shields.io/github/v/release/ZephyrKeXiner/AhaKey-Studio?include_prereleases&label=release&color=4F46E5" alt="最新リリース"></a>
<a href="https://github.com/ZephyrKeXiner/AhaKey-Studio/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/ZephyrKeXiner/AhaKey-Studio/ci.yml?branch=main&label=build" alt="ビルド"></a>
<a href="https://github.com/ZephyrKeXiner/AhaKey-Studio/commits/main"><img src="https://img.shields.io/github/last-commit/ZephyrKeXiner/AhaKey-Studio?color=informational" alt="最終コミット"></a>
<a href="https://github.com/ZephyrKeXiner/AhaKey-Studio/stargazers"><img src="https://img.shields.io/github/stars/ZephyrKeXiner/AhaKey-Studio?style=flat&color=4F46E5" alt="Stars"></a>

<br/>

<img src="https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white" alt="macOS 13+">
<img src="https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white" alt="Swift">
<img src="https://img.shields.io/badge/UI-SwiftUI-007AFF?logo=swift&logoColor=white" alt="SwiftUI">
<img src="https://img.shields.io/badge/Xcode-App%20Target-147EFB?logo=xcode&logoColor=white" alt="Xcode App Target">
<img src="https://img.shields.io/badge/Plugin%20SDK-TypeScript-3178C6?logo=typescript&logoColor=white" alt="TypeScript Plugin SDK">

</div>

## 概要

AhaKey Desktop は **AhaKey-X1（Vibecoding Keyboard）** 向けのコンパニオンスイートです。キーボード設定、物理スイッチによる AI 承認、macOS 上の音声エージェントを提供します。独立 Studio Frontend への移行状況と機能の制限は、以下の開発文書を参照してください。

<a id="documentation"></a>

## ドキュメント

| 文書 | 内容 |
|---|---|
| [言語別ドキュメント一覧](../README.md) | 中英日の対応範囲と翻訳の保守方針 |
| [プロジェクト概要（英語）](../overview.md) | 機能、クライアント、ビルド、リポジトリ構成 |
| [インストール（中国語）](../installation.md) · [ダウンロード](https://github.com/ZephyrKeXiner/AhaKey-Studio/releases) | ソースからのビルドとインストーラー |
| [SDK 概要（英語）](../../sdks/README.md) · [TypeScript ガイド（英語）](../../sdks/typescript/README.md) | プラグイン開発、API、サンプル |
| [アーキテクチャ](architecture.md) · [BLE 仕様（中国語）](../ble-protocol.md) | システム構成と実機通信 |
| [独立 Studio 開発](studio-frontend.md) · [分離計画](studio-frontend-extraction.md) | SwiftUI ターゲット、Mock、移行手順 |
| [Rust 接続ガイド](rust-backend-integration.md) · [Runtime プロトコル](../../contracts/runtime-v1/README.ja.md) | WebSocket、設定、操作復元、接続検証 |
| [アプリのローカライズ（中国語）](../localization.md) | 中国語・英語・日本語、言語選択と検証 |
| [コントリビュート（英語）](../../CONTRIBUTING.md) | 不具合報告、PR、検証 |

<a id="star-history"></a>

## ⭐ Star 履歴

AhaKey が役立ったら、[GitHub で Star](https://github.com/ZephyrKeXiner/AhaKey-Studio) を付けてください。下のグラフでコミュニティの成長を確認できます。

<p align="center">
  <a href="https://www.star-history.com/#ZephyrKeXiner/AhaKey-Studio&amp;Date">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=ZephyrKeXiner/AhaKey-Studio&amp;type=Date&amp;theme=dark">
      <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=ZephyrKeXiner/AhaKey-Studio&amp;type=Date">
      <img width="700" src="https://api.star-history.com/svg?repos=ZephyrKeXiner/AhaKey-Studio&amp;type=Date" alt="AhaKey Desktop Star 履歴">
    </picture>
  </a>
</p>

<a id="contributing"></a>

## 🤝 コントリビュート

不具合報告、提案、文書、翻訳、コードの改善を歓迎します。[貢献ガイド（英語）](../../CONTRIBUTING.md)を読み、[GitHub Issues](https://github.com/ZephyrKeXiner/AhaKey-Studio/issues) で意見をお寄せください。

<p align="center">
  <a href="https://github.com/ZephyrKeXiner/AhaKey-Studio/graphs/contributors">
    <img src="https://contrib.rocks/image?repo=ZephyrKeXiner/AhaKey-Studio" alt="AhaKey Desktop の貢献者">
  </a>
</p>
