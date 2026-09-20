# 独立 Studio フロントエンドの開発

[English](../studio-frontend.md) · [简体中文](../zh/studio-frontend.md) · **日本語**

> 対象ブランチ：本書は [`dev`](https://github.com/AhakeyAI/AhaKey-Studio-mac/tree/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c) の Studio/Rust 実装を説明します。今回 main に追加するのは文書だけです。フロントエンドのコマンドは該当実装をチェックアウトしたディレクトリで実行してください。この文書ブランチに実装ソース、fixture、ビルドターゲットは含まれません。

`dev` は origin/main の 2f77109 から作成しました。今回の実装はフロントエンド分離の第 1 段階で、旧アプリを移行の比較対象として残しています。Rust リポジトリは変更していません。

Rust 側の開発は [Rust Runtime 接続ガイド](rust-backend-integration.md)から始めてください。サーバー設定、インターフェースの意味、初期設定の制約、接続検証の受け入れ条件を説明しています。

## 起動方法

Xcode で AhaKey Studio.xcodeproj を開きます。

- **Studio Frontend Mock**：実機やバックエンドなしで、四モードのキー、マクロ、灯、全体の明るさ、ローカル GIF を編集できます。MOCK バナーを表示し、メニューから切断、受理応答の消失、部分書き込み失敗、外部設定変更を再現できます。
- **Studio Frontend**：実際の IPC クライアントです。現在のユーザーの Runtime discovery を読み、バックエンドが不在でもドラフトを編集でき、自動再接続します。旧 Agent の起動や Swift BLE への切り替えは行いません。
- **AhaKey Studio**：旧 Swift バックエンドと Bluetooth を含む完全なアプリです。移行時の比較用に残しています。Rust に実機を渡す前に旧管理プロセスを停止してください。

コマンドラインでの検証：

```sh
python3 scripts/check-frontend-boundary.py
python3 scripts/check-localizations.py
xcodebuild -project "AhaKey Studio.xcodeproj" -scheme "Studio Frontend" \
  -configuration Debug -destination "platform=macOS,arch=arm64" \
  -derivedDataPath DerivedData/Frontend \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual test
```

Intel Mac では arch を x86_64 に変更します。Mock scheme は --mock-runtime を渡します。ビルドしたアプリを直接実行するときも指定できます。

## コードの責務

| 場所 | 責務 |
|---|---|
| `StudioFrontend/App` | 独立したアプリのライフサイクル、Runtime 状態の VibeBar への反映 |
| `StudioFrontend/Views` | 画面と編集操作。ハードウェアを呼び出さない |
| `StudioFrontend/State/StudioDraftStore.swift` | ドラフト永続化、全体の明るさ、業務設定への変換 |
| `StudioFrontend/State/RuntimeStore.swift` | スナップショットとイベントの反映、sequence と購読の分離、外部変更による無効化 |
| `StudioFrontend/State/StudioModel.swift` | 再接続、基準状態、未確定操作の永続化と結果照会 |
| `StudioFrontend/Runtime` | DTO、業務インターフェース、メモリー内 Mock、WebSocket アダプター |
| `AhaKey Studio/SharedPresentation` | 両ターゲットで共有するキーボード、ショートカット編集、GIF、アカウント、HID 表示、IDE 状態 |
| `AhaKey Studio/Services/Bluetooth/LegacyDraftEncoding.swift` | 旧ターゲット専用の灯とマクロのファームウェア形式への変換 |
| `contracts/runtime-v1` | 現行仕様の範囲、JSON Schema、固定サンプル |

新ターゲットのターゲット依存は VibeBar のみです。旧 Agent、CoreBluetooth、OLED の実機向け変換、ファームウェア書き込みプログラムは含めません。共通ソースは明示的に追加し、旧ソース全体の自動取り込みを避けます。CI はソース境界チェックと独立フロントエンドテストを実行します。

## 状態とデータ

編集対象モードと実機モードは別です。タブを切り替えてもキーボードの動作モードは変わりません。GIF 選択や灯の変更はドラフトとローカルプレビューだけを更新します。設定を保存するときにバックエンドへ送信します。

Mock と実接続では UserDefaults domain を分けます。ai.ahakey.studio.frontend.mock と ai.ahakey.studio.frontend です。実接続の初回起動では旧 ahakey.studio.draft.v1 を読み取り専用でコピーします。Debug は旧 .debug domain を優先し、Release は旧正式版を使います。旧設定は変更しません。明るさは旧 Mode 0 からデバイス共通値として取り出します。新ドラフトが存在すれば旧データで上書きしません。

新しく読み込む GIF は `~/Library/Application Support/AhaKey/StudioFrontend/Assets` へコピーし、ローカルパスを Runtime に送りません。旧ドラフトの独自アセットパスは保持しますが、元ファイルがなければ再選択が必要です。旧モードの別名、Hook ポリシー、音声ルーティングは移行しておらず、旧アプリが管理します。

バックエンド状態はドラフトを上書きしません。外部設定変更時は保存を止め、ユーザーが確認して基準状態を読み直します。その際もドラフトは保持し、次の保存で選択範囲を明示的に上書きします。保存中の追加編集は、先行する操作が完了しても保存済みとは扱いません。

送信前に operationId と元の要求を記録します。切断や応答消失時は元の操作を照会し、設定を自動再送しません。部分失敗では書き込み可能な基準状態を破棄します。操作が検索できなければ結果不明として保持し、ユーザーが実機を確認します。Studio 終了時は接続のみ閉じ、Runtime の停止や操作取消は要求しません。

## 現在の範囲

メモリー内 Mock と独立 Python WebSocket fixture に接続済みです。テストは実 WebSocket の通信と解析を検証しますが、Rust Runtime や実機との結合は未検証です。Rust は[現行プロトコル](../../contracts/runtime-v1/README.ja.md)に従って実装してください。

保存対象はキー、灯、全体の明るさです。OLED 転送、実機の灯プレビュー、Hook 管理、音声待ち受け、テキスト入力、ファームウェア書き込みは今後の Runtime 接続で対応し、UI でも制限を示します。アカウント画面は既存クラウド実装を再利用します。フロントエンドは Bluetooth、マイク、入力監視の権限を要求しません。

現在はスナップショットの先頭デバイスだけを表示し、明示的スキャンや複数デバイス選択はありません。不明な電池残量やスイッチ状態は不明のまま表示します。Rust の接続・状態・設定処理を先に完成させ、その後に残りの機能を移行し、最後に旧リリースターゲットを置き換えます。
