# アーキテクチャ

[English](../architecture.md) · [简体中文](../zh/architecture.md) · **日本語**

> 対象ブランチ：本書は [`dev`](https://github.com/AhakeyAI/AhaKey-Studio-mac/tree/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c) の Studio/Rust 実装を説明します。今回 main に追加するのは文書だけです。フロントエンドのコマンドは該当実装をチェックアウトしたディレクトリで実行してください。この文書ブランチに実装ソース、fixture、ビルドターゲットは含まれません。

このリポジトリは macOS Studio の Xcode プロジェクトです。古い文書にある Windows、Linux、BLE TCP bridge、ルートの Package.swift は、以前の Desktop モノレポを説明したものです。

## 二つのアプリケーション

`AhaKey Studio` は移行前の完全な Swift アプリです。デバイス設定、音声、アカウント、ファームウェア書き込みと、Tools/Agent のバックグラウンド daemon / Hook CLI を含みます。現在も Swift CoreBluetooth がハードウェアを管理し、Studio と daemon の間で旧方式の接続所有権を切り替えます。

`Studio Frontend` は独立した Rust Runtime 向けの SwiftUI クライアントです。このターゲットは BLE、旧 Agent、ファームウェアコマンドのエンコード、書き込み実行プログラムを含みません。Studio Frontend Mock scheme なら実機なしで開発できます。実接続ではローカル WebSocket と JSON-RPC を使用します。[現在のプロトコル](../../contracts/runtime-v1/README.ja.md)を参照してください。Rust は別リポジトリにあり、結合検証はまだ完了していません。

```text
Studio Frontend → StudioModel → RuntimeClient → ローカル IPC → Rust Runtime → キーボード
                      ├─ StudioDraftStore：ユーザーのドラフト
                      └─ RuntimeStore：バックエンド状態と操作結果
                                   └─ RuntimeVibeBarBridge → VibeBar
```

Rust Runtime はデバイス接続を一元管理し、設定、アセット転送、Hooks、ファームウェア書き込みを実行する設計です。Studio を終了しても閉じるのはクライアント接続だけで、Runtime は終了しません。現在の Mock/fixture は、これらのバックエンド機能が実装済みであることを示すものではありません。

## ソース構成

| ディレクトリ | 役割 |
|---|---|
| `StudioFrontend/` | 新しい起動処理、画面、ドラフト、バックエンド状態、IPC、Mock |
| `AhaKey Studio/App`, `Features`, `Services` | 旧アプリの起動処理と全機能。新ターゲットは一部の純粋なモデルとアカウント実装を明示的に再利用 |
| `AhaKey Studio/SharedPresentation` | 共通のキーボード画面、ショートカット編集、GIF プレビュー、アカウント画面、表示モデル |
| `Modules/VibeBar` | 共通の macOS オーバーレイ UI |
| `Modules/AhaKeyPluginKit`, `sdks/typescript` | 既存プラグインホストと stdio JSON-RPC SDK。Runtime SDK ではない |
| `Tools/Agent` | 旧 Swift daemon と各ツールの Hook CLI |
| `contracts/runtime-v1` | 新フロントエンドが使用する Schema と fixture |
| `Tests/StudioFrontendTests` | フロントエンド状態、操作復元、実 WebSocket fixture との結合テスト |

## 状態と実行の制約

- Studio のドラフトと Runtime の正規状態は分けて保存します。編集モードの選択では実機モードを変更しません。
- フロントエンドは設定の意図を送信し、BLE bytes、Flash アドレス、実機書き込み順序を組み立てません。
- スナップショットとイベントで状態を復元します。request id は接続内の応答対応付け、operationId は接続をまたいだ操作照会に使用します。
- 設定の基準状態が失効したら保存を禁止します。不明な状態を既定の電池残量や自動承認状態で置き換えません。
- Rust に実機を渡す前に旧 BLE 管理プロセスを停止します。IPC 障害時に旧 Bluetooth 実装へ自動切り替えしません。
- macOS の音声、入力処理、権限は、それを実行するプロセスが担当します。新フロントエンドは現在これらを起動しません。

起動、データ移行、制限は[独立フロントエンド開発](studio-frontend.md)、移行全体は[分離計画](studio-frontend-extraction.md)を参照してください。クラウドアカウントサービスと Rust バックエンドはこのリポジトリに実装されていません。
