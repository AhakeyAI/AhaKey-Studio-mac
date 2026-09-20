# Studio フロントエンド第 1 段階のプロトコル

[English](README.md) · [简体中文](README.zh-CN.md) · **日本語**

> 対象ブランチ：本書は [`dev`](https://github.com/AhakeyAI/AhaKey-Studio-mac/tree/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c) の Studio/Rust 実装を説明します。今回 main に追加するのは文書だけです。フロントエンドのコマンドは該当実装をチェックアウトしたディレクトリで実行してください。この文書ブランチに実装ソース、fixture、ビルドターゲットは含まれません。

本書は StudioFrontend/Runtime が使用し、Mock と独立 WebSocket fixture で検証済みのインターフェース範囲です。Rust Runtime では未実装であり、このディレクトリは実機互換性の証明ではありません。以前の docs/runtime-studio-*.md にある広い機能計画は今後の設計です。ここでは現クライアントが実際に送受信するフィールドを定義します。

schema.json が通信データを定義し、fixtures/ が固定 JSON サンプルを提供します。Rust のデシリアライズテストにも同じ fixture を使用し、言語既定の enum 形式に依存しないでください。現在の Apply.changes.modes[].lights は {state,effect} オブジェクトの配列です。モデルを拡張する場合は、バージョン、両側の DTO、fixture を合わせて更新します。

実装と接続検証は [Rust バックエンド接続ガイド](../../docs/ja/rust-backend-integration.md)を参照してください。

## 接続

クライアントは現在のユーザー専用の discovery ファイルを読みます。

```json
{"endpoint":"ws://127.0.0.1:12345/","token":"example-only"}
```

既定パスは `~/Library/Application Support/AhaKey/runtime/discovery.json` です。AHAKEY_RUNTIME_DISCOVERY で別ファイルを指定できます。現在のユーザーが所有する通常ファイルで、他ユーザーへの権限がなく（0600 推奨）、16 KiB 未満である必要があります。loopback IP の ws アドレスだけを許可し、URL の認証情報、query、fragment、HTTP リダイレクトを拒否します。実サーバー側でも認証、Origin、クライアント権限の検証が必要です。

WebSocket のテキストメッセージ一つに JSON-RPC 2.0 オブジェクトを一つ格納します。request id は文字列、メッセージ上限は 1 MiB、同時要求は最大 32 件、タイムアウトは 10 秒です。フロントエンドは単一受信ループと直列送信を使い、順不同の応答を id で対応付けます。

最初の要求は runtime.hello です。

```json
{"jsonrpc":"2.0","id":"hello-1","method":"runtime.hello","params":{"protocol":{"major":1,"minor":0},"client":{"name":"AhaKey Studio","version":"0.1.0","kind":"studio"},"token":"example-only"}}
```

result の形式は fixtures/hello.json を参照してください。major は 1 にし、methods は実際に対応するメソッドだけを宣言します。

## メソッドとイベント

| メソッド | params | result |
|---|---|---|
| `runtime.subscribe` | `{"topics":["state"],"cursor":null}` | Subscription |
| `configuration.get` | `{"deviceId":"..."}` | ConfigurationDocument |
| `configuration.apply` | Apply | `{"operationId":"...","status":"accepted"}` |
| `operation.get` | `{"operationId":"..."}` | Operation |
| `device.connect` / `device.disconnect` | `{"deviceId":"..."}` | 任意の JSON。フロントエンドは内容を使用せず、状態イベントを待つ |

バックエンドはデバイスを発見し、接続候補をスナップショットへ載せます。最初の UI はその先頭デバイスを使用します。明示的なスキャンや複数デバイス選択は未実装です。Rust の初回検証では既知の X1 一台を公開できます。

購読登録とスナップショット取得をアトミックに行い、応答を送信した後で、それより新しいイベントを送ります。

```json
{"jsonrpc":"2.0","method":"runtime.event","params":{"subscriptionId":"...","instanceId":"...","sequence":"9007199254740994","type":"device.changed","data":{"deviceId":"x1","name":"AhaKey","connectionState":"ready","batteryPercent":null,"workMode":0,"lever":"manual"}}}
```

- device.changed は完全な Device を含みます。保存には connectionState=ready が必要です。lever は automatic/manual で、不明値は不明のまま表示します。
- operation.changed は完全な Operation を含みます。status は accepted/running/completed/failed/cancelled、effect は none/partial/unknown/complete です。
- configuration.changed / configuration.invalidated は最低限 deviceId を含み、古い基準状態による保存を止めます。
- sequence は UInt64 の十進文字列です。JavaScript 安全整数を超える値もテストしています。フィルター後のグローバル sequence に欠番は許容されます。
- 購読応答の引き継ぎ中はイベントを保持し、古い購読・instance・sequence を無視します。再接続では新規スナップショットを要求し、イベント再生には依存しません。

## 設定と操作

保存要求には選択モードごとの全四キーと九つの IDE 状態の灯設定、デバイス共通の明るさを含めます。scope と changes を一致させ、mode/role/state の重複はサーバーで拒否します。action は shortcut/macro/disabled、modifier は control/shift/alt/gui、keyCode は HID usage、delayMs はミリ秒です。X1 制限の最終検証はバックエンドの責任です。説明は ASCII 20 バイト以内、マクロは 49 ステップ以内、遅延は 3ms の倍数で最大 765ms にします。フロントエンド検証だけでは不十分です。

完全な設定を確定できない場合、configuration.get は configuration:null を返します。ドラフトを保持して保存を禁止し、既定値を実機の事実として表示しません。現段階では一部フィールドが不明な状態での書き込みはできず、根拠モデルの拡張が必要です。

operationId は送信前にローカル保存します。同じ ID・同じ内容は重複排除し、異なる内容は OPERATION_ID_CONFLICT を返します。受理応答を失っても自動再送せず、再接続後に同じ ID を照会します。OPERATION_NOT_FOUND は結果不明です。ユーザーが実機を確認して追跡を終了した後も、次の保存前に基準状態を読み直します。

completed はバックエンドが定めたすべての確認条件を満たしたことを意味します。フロントエンドは ACK 完了を計算せず、accepted を成功とはみなしません。部分失敗は effect=partial/unknown を報告し、ロールバックしたと主張しないでください。操作記録の保存期間と、再起動後の不明な結果の扱いを定義する必要があります。

エラーは JSON-RPC error を使い、error.data.code に BASE_CONFLICT、DEVICE_NOT_READY、DEVICE_TIMEOUT、BUSY、INCOMPLETE_WRITE_GROUP、OPERATION_NOT_FOUND などの安定したコードを入れます。任意の error.message は UI に表示しません。標準の -32602/-32601 は INVALID_PARAMS/UNSUPPORTED_CAPABILITY に対応します。

アセット転送、実機プレビュー、Hooks、音声ホスト、ファームウェア書き込み、完全な権限モデルは今回の範囲外です。選択した GIF は Studio ドラフトに残り、configuration.apply に含めません。Flash アドレス、RGB565、パケットサイズ、ファームウェア形式はこのインターフェースに公開しません。

## ローカル接続検証

python3 scripts/mock-runtime-server.py を実行すると、stdout に一時 discovery パスが出ます。Xcode の AHAKEY_RUNTIME_DISCOVERY に設定して Studio Frontend scheme を実行します。このサーバーは単一クライアント用 fixture で、複数クライアント配信、本番用保存、実機検証、アセット転送はありません。実 Runtime として配布しないでください。

StudioFrontendTests.testRealWebSocketClientAgainstPythonFixture はサーバーを自動起動し、URLSession WebSocket の実ハンドシェイク、認証、設定取得・送信、イベント、操作照会を確認します。テスト終了時にサーバーを停止します。
