# origin から Studio フロントエンドを分離する計画

[English](../studio-frontend-extraction.md) · [简体中文](../zh/studio-frontend-extraction.md) · **日本語**

> 対象ブランチ：本書は [`dev`](https://github.com/AhakeyAI/AhaKey-Studio-mac/tree/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c) の Studio/Rust 実装を説明します。今回 main に追加するのは文書だけです。フロントエンドのコマンドは該当実装をチェックアウトしたディレクトリで実行してください。この文書ブランチに実装ソース、fixture、ビルドターゲットは含まれません。

調査日：2026-09-20。本書は当初の調査と全体計画を記録します。第 1 段階はその後 dev に実装しました。現在の構成、起動方法、残る範囲は[独立フロントエンド開発](studio-frontend.md)を参照してください。Rust/実機との結合は未検証です。

## 調査時点と結論

- AhakeyAI/AhaKey-Studio-mac に対して git fetch origin を実行し、origin/main は 2f77109 でした。
- 当時のローカル main は bdec7b3 で二コミット遅れていました。差分は日本語翻訳、関連 Xcode 設定、ローカライズ文書で、調査した Swift ソースは origin/main と同じでした。
- Rust リポジトリの HEAD は a4e4b29 でした。作業ツリーには BLE 探索、接続、購読、コマンド書き込み、状態解析の初期実装がありましたが、Studio 向け IPC はありませんでした。
- cargo check --locked --offline は失敗しました。src/ahakey/model_x1.rs:25 で JoinHandle<()> 型の listener に None を代入していました。これはビルド阻害要因であり、それを直すだけで Runtime が完成するわけではありません。
- 未追跡の runtime-studio-current-desktop-design.md は以前の設計稿です。「Rust は探索して出力するだけ」という記述は古く、責務分担は参考になりますが、実装済みの契約ではありません。

既存 SwiftUI Studio を維持し、独立 Rust Runtime がデバイス接続を所有する構成を推奨します。まずフロントエンドと交換可能な Runtime インターフェースを分離し、その後に Rust 実装へ接続します。このリポジトリは既に多プラットフォーム Desktop から macOS 専用プロジェクトとして分かれており、残る主な作業はプロセス内で結合した責務の分離です。

本計画は SwiftUI を継続使用する前提です。Web/クロスプラットフォーム UI も必要なら、キーボード画面と各 SwiftUI ページを別途実装します。バックエンドを Rust にすることだけで UI の書き直しは必要ありません。

## 目標構成

```text
Studio（SwiftUI プロセス）
  Views / VibeBar / 権限案内 / アカウント画面
      ↓
  StudioModel
    ├─ StudioDraftStore：編集ドラフト、ローカル素材、選択状態
    ├─ RuntimeStore：バックエンドのスナップショット、実機状態、進捗
    └─ RuntimeClient：業務要求、購読、再接続
             ↓ ローカル IPC
Rust Runtime（独立バックグラウンドプロセス）
  デバイス接続 / 状態 / 設定 / アセット / Hooks / ファームウェア書き込み
             ↓
           キーボード

macOS 機能：音声、入力監視、テキスト入力
  移行中は Swift 実装を維持し、Studio 終了後も必要なら別プロセスで管理
```

Studio を終了しても、Rust Runtime と受理済みの実機操作は継続させます。インストーラーで Studio、Runtime、補助プログラムをまとめて配布できます。独立プロセス、独立ビルド、別インストーラーはそれぞれ別の選択です。

## 既存の結合箇所と責務

パスはリポジトリルート基準です。行番号は最初の調査時点を示します。

| 場所 | 既存の動作 | 分離作業 |
|---|---|---|
| `AhaKey Studio/App/AhaKeyWorkspaceView.swift:6` | ワークスペースが BLE manager を直接作成 | アプリ共通の StudioModel を注入し、接続寿命を管理 |
| `AhaKey Studio/App/RootView.swift:5` | ページと権限案内が BLE manager に依存 | Runtime の状態を参照し、システム設定への移動はプラットフォーム層に残す |
| `AhaKey Studio/Features/Studio/AhaKeyStudioView.swift:9` | 5,057 行で BLE、Agent、音声、アカウントに直接依存 | 動作と状態を抽出後、キャンバス、インスペクター、状態バーなどへ分割 |
| 同ファイル `:2185`, `:2322` | 画像転送、コマンド構築、ACK 待ち、実機保存 | フロントエンドは設定意図を送信し、順序と確認条件は Rust へ移す |
| 同ファイル `:2090` 付近 | Studio/Agent 間の BLE 所有権切り替え | Rust 接管後に操作と過渡状態を削除 |
| 同ファイル `:2410` 付近 | 接続後に View が既定 OLED を自動転送 | Runtime の明示的な素材導入ポリシーにし、画面表示を実機書き込みの契機にしない |
| `AhaKey Studio/Features/Studio/AhaKeyStudioModels.swift` | 表示、ドラフト保存、ファームウェア bytes が混在 | 表示とドラフトを残し、独立 DTO を追加、デバイス形式を分離 |
| `AhaKey Studio/Services/Bluetooth/AhaKeyBLEManager.swift` | BLE、Agent ファイル監視、通知表示が混在 | BLE/監視を除き、SwitchStateNotifier などは RuntimeStore を購読 |
| `AhaKey Studio/Services/Bluetooth/AhaKeyProtocol.swift` | コマンド変換、IDEState、HIDUsage が同居 | 変換は Rust へ、状態名・キー表示はフロントエンドのモデルへ分離 |
| `AhaKey Studio/Features/OLED/OLEDFrameEncoder.swift` | GIF を実機ピクセルへ変換 | 変換は Rust、ファイル選択と動画プレビューは Studio |
| `AhaKey Studio/Services/Agent/AgentManager.swift` | 1,802 行。所有権、インストール、起動、Hook 変更 | Runtime 起動/導入を分離、Hook 管理はバックエンドへ、所有権切り替えを削除 |
| `Tools/Agent/` | 旧 Swift daemon とツール Hooks | 実行機能を移し、互換期間は転送専用 CLI を残せるが BLE を所有させない |
| `AhaKey Studio/Features/Studio/VibeBarBridge.swift:11` | BLE/音声 singleton を直接購読 | RuntimeStore/音声状態を購読し、Modules/VibeBar は維持 |
| `AhaKey Studio/Features/Firmware/` | View が flasher を作り wchisp を実行 | 操作と進捗表示を残し、事前検査・消去・書き込み・プロセス管理は Runtime |
| `Modules/AhaKeyPluginKit/PluginHost.swift:126` | 旧 /tmp/ahakey.sock でスイッチを照会 | Runtime アダプターへ変更、プラグイン stdio 仕様は維持 |
| `sdks/typescript/` | 現在はプラグイン SDK | 実装済み Runtime SDK とみなさず、別途クライアントを追加 |
| `AhaKey Studio/Features/Account/` | クラウドアカウント操作 | 初期段階は維持。登録・決済の Rust 移行は必須ではない |
| `AhaKey Studio/Features/Voice/`, `AppDelegate.swift` | アプリが音声待ち受けと macOS 機能を実行 | プラットフォーム実装を分離。プロセス内に残す間は Studio 終了で音声も止まることを明示 |

AhaKeyBLEManager のメソッドを一つずつ RPC にコピーしないでください。それでは bytes、Flash アドレス、書き込み順序、復旧処理への依存が UI に残ります。

## 最初に実装するフロントエンド構成

通常のディレクトリと少数の明示的なターゲットで始めます。すべてを個別 Swift package にする必要はありません。

```text
AhaKey Studio/
  App/                         # アプリ構成、ウィンドウ、メニュー
  Features/                    # 編集と表示
  Models/                      # 業務モデルと表示変換
  State/
    StudioModel.swift          # ユーザー操作、ドラフトとバックエンド状態の調整
    StudioDraftStore.swift     # 旧データ移行と未保存編集
    RuntimeStore.swift         # ドラフトと分けた正規状態
  Runtime/
    RuntimeClient.swift        # 業務用 Swift インターフェース
    RuntimeDTOs.swift          # SwiftUI/CoreBluetooth 非依存の通信モデル
    IPCRuntimeClient.swift     # 実 IPC アダプター
    MockRuntimeClient.swift    # オフライン開発
  Platform/macOS/             # 設定画面、音声、プラットフォーム連携
  Resources/
  Localization/
```

Mock と IPC は同じ業務インターフェースを実装します。移行中に Legacy adapter を追加する場合も、明示的に選んだ旧モードだけで使用します。Rust モードで Swift BLE を起動したり、切断時に自動で直接接続へ戻ったりしてはいけません。

## 初期インターフェースの範囲

以前のローカル WebSocket + JSON-RPC 方針を継続し、意味と固定 JSON サンプルを定めてから両側を実装します。この節のメソッド名は提案で、現在の Runtime 対応機能を示すものではありません。

| メソッド群 | フロントエンドが必要とする機能 |
|---|---|
| `runtime.hello`, `runtime.subscribe` | バージョン・機能交渉、アトミックなスナップショットと後続イベント |
| `device.discover/connect/disconnect` | 接続意図を送信し、IPC 接続と実機接続を区別 |
| `configuration.get/apply` | 基準状態付き設定の取得、変更送信、operationId 返却 |
| `operation.get` | 再接続後に同じ操作を照会し、盲目的な再書き込みを避ける |
| `device.preview/endPreview` | 一時プレビュー。期限切れと復元は Runtime が担当 |

最初に状態表示と画像以外の保存を完成させ、その後にアセット、Hooks、音声、ファームウェア書き込みを追加します。未実装メソッドを対応済みと宣言しないでください。

次の意味を明確にします。

- Runtime 接続、キーボード状態、ユーザードラフトは別です。不明な電池残量やスイッチを 0 で埋めません。
- configuration.apply は shortcut/macro/disabled、説明、灯などの業務値を持ち、BLE bytes や既存 StudioDraft 全体を送りません。
- 旧ドラフトのマクロ遅延は 3ms 単位です。ミリ秒への変換を明示的に行い、灯の固有番号で UI から実機を操作しません。
- 明るさはデバイス共通設定です。旧ドラフトにはモード別にありますが、実コマンドにモード引数はありません。
- localAssetPath、翻訳文、UI 状態はプロセス境界を越えません。アップロード済み素材は resourceId で参照します。
- 受理は成功ではありません。進捗は Runtime が持ち、operationId、基準状態競合、部分失敗の意味を維持します。
- IPC 切断後は新しいスナップショットから復元し、未保存ドラフトを保持します。既定値も直前の送信値も読み戻しの証拠にはなりません。
- 固定ポートだけでなく、discovery、認証、バージョン、実際の権限所有プロセスを一緒に定めます。

## 実装段階と受け入れ

以下は当初の計画です。第 1 段階はユーザー指定によりローカル dev で実装し、アーキテクチャ文書も更新しました。

1. **独立起動できるフロントエンド。** 当初は更新済み origin/main から codex/studio-frontend を作る提案でしたが、実作業は dev を使用しました。中英日のアプリ資源を保持し、DTO、Store、RuntimeClient、Mock を分離します。Runtime 不在でも起動・ドラフト編集・利用不可表示ができ、Mock で接続・進捗・失敗を再現します。
2. **Rust 状態接続。** ビルドを直し、hello/subscribe、実機接続、状態通知を実装します。旧 BLE 管理を止めてから Rust に渡します。移行中は旧リリースを戻し先として残し、二つの管理プロセスを同時実行しません。
3. **設定処理。** 画像以外の設定、macro/shortcut 相互クリア、説明、灯、全体の明るさ、コマンド別 ACK を移行します。Studio は設定送信と操作表示を担い、その後に主要 UI の BLE 所有権切り替えを除去します。
4. **残りの機能。** OLED アセットとプレビュー、Hook/プラグイン照会、ファームウェア書き込みを追加します。音声ホストを分離し、権限案内を実行プロセスに合わせます。既定 OLED の自動転送や、ドラフト編集が直ちに音声経路へ影響する暗黙動作も修正します。
5. **ビルドと配布の整理。** 旧 AhaKeyConfigAgent と Embed Agent への Studio ビルド依存を除去します。書き込み用資源のコピー/検証を移し、CI、インストール、構成文書を更新します。最初の調査時点の構成文書は旧多プラットフォーム構成を記載していました。

Xcode はファイルシステム同期ディレクトリを使います。旧実装を AhaKey Studio/Legacy に移すだけではコンパイルから外れません。同期ルート外への移動、ターゲット所属の例外、明示的 Legacy ターゲットのいずれかを使い、依存テストも更新してください。

第 1 段階で得られるのは独立開発可能なフロントエンドです。完全なリリースの置き換えには実機接続の完成が必要です。未接続機能は利用不可と表示し、Mock の成功を実機書き込み成功として扱わないでください。

## 完了条件

- フロントエンドに CoreBluetooth、実機コマンド変換、Flash 配置、旧 Agent 接続監視が含まれない。
- 実接続では Rust が唯一のデバイス管理者となり、Studio 終了後も接続と受理済み操作が継続する。
- Swift/Rust が同一 JSON fixture で仕様を検証し、フロントエンドと Mock を独立ビルド・開発できる。
- 再接続でドラフトを失わず、重複書き込みしない。外部変更は競合となり、不明な結果と成功を区別できる。
- 一モード/全モード保存、macro/shortcut 変換、OLED 転送中の切断、Hooks と設定の並行動作、取消不能な書き込み段階を実機テストする。
- 音声プロセスの寿命、権限所有、UI 案内が一致し、旧ドラフト・素材パス・ユーザー連携の移行を追跡できる。

最初の調査ではソース、リモート差分、Rust ビルド結果だけを確認しました。その後、指定されたローカル dev で第 1 段階を実装しました。実機コマンド送信やファームウェア書き込みは実行していません。
