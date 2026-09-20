# Studio 向け Rust Runtime 接続ガイド

[English](../rust-backend-integration.md) · [简体中文](../zh/rust-backend-integration.md) · **日本語**

> 対象ブランチ：本書は [`dev`](https://github.com/AhakeyAI/AhaKey-Studio-mac/tree/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c) の Studio/Rust 実装を説明します。今回 main に追加するのは文書だけです。フロントエンドのコマンドは該当実装をチェックアウトしたディレクトリで実行してください。この文書ブランチに実装ソース、fixture、ビルドターゲットは含まれません。

本書は `dev` で実装された **Studio Frontend** ターゲットのプロトコル `1.0` を説明します。Rust Runtime がデバイス接続、状態管理、設定書き込みを担当し、SwiftUI フロントエンドはローカル WebSocket 経由で呼び出します。記載するクライアントの動作は実装済みですが、Rust サーバーと実機を組み合わせた検証はまだ完了していません。

フィールドの定義は [RuntimeDTOs.swift](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/StudioFrontend/Runtime/RuntimeDTOs.swift)、[IPCRuntimeClient.swift](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/StudioFrontend/Runtime/IPCRuntimeClient.swift)、[プロトコル fixture](https://github.com/AhakeyAI/AhaKey-Studio-mac/tree/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/contracts/runtime-v1/fixtures) を参照してください。以前の `runtime-studio-*.md` には将来構想も含まれるため、現在のクライアント仕様としてそのまま使用しないでください。

## 1. 実装する機能

現在のユーザー権限で独立動作する Rust プロセスに、次の七つのメソッドを実装します。

| メソッド | 目的 | 応答するタイミング |
|---|---|---|
| `runtime.hello` | token 認証、バージョン交渉、対応機能の宣言 | 認証後すぐに応答 |
| `runtime.subscribe` | 状態購読の登録と整合性のあるスナップショット取得 | 登録後すぐに応答 |
| `configuration.get` | 設定の基準状態とバージョン token の取得 | 信頼できる状態を読み取り、長時間のスキャンは待たない |
| `configuration.apply` | 設定操作の検証と受理 | 操作を永続化して `accepted` を返し、デバイス書き込みは非同期実行 |
| `operation.get` | 元の操作を照会し、失われた結果を復元 | 操作記録から読み取る |
| `device.connect` | 指定デバイスへの接続要求 | キュー投入後に応答し、接続結果はイベントで通知 |
| `device.disconnect` | デバイス切断要求 | キュー投入後に応答し、状態はイベントで通知 |

最初の三つで接続と読み取りを検証できます。保存処理には configuration.apply、operation.get、状態イベントも必要です。フロントエンドは Runtime を起動せず、旧 Swift Bluetooth バックエンドにも切り替わりません。Studio の終了では WebSocket のみ閉じ、Runtime や受理済み操作は停止しません。

```text
Studio Frontend
  └─ ローカル WebSocket / JSON-RPC 2.0
       └─ Rust：認証、購読、設定の基準状態、操作記録、デバイス別書き込みキュー
            └─ Rust デバイスアダプター：BLE、ファームウェア形式、ACK、タイムアウト、状態取得
                 └─ AhaKey X1
```

## 2. 起動と discovery の設定

推奨する起動順序：

1. 設定と操作記録を復元し、プロセス起動ごとに新しい instanceId を生成します。
2. `127.0.0.1` または `::1` のみで待ち受けます。OS が割り当てた空きポートを使用できます。
3. 推測困難なセッション token を生成し、待ち受け開始後に discovery ファイルをアトミックに公開します。
4. デバイス探索と状態管理を開始します。探索中のスナップショットは空のデバイス一覧でも構いません。

discovery の既定パス：

```text
~/Library/Application Support/AhaKey/runtime/discovery.json
```

ファイル例です。ポートと token は実際の値に置き換えてください。

```json
{
  "endpoint": "ws://127.0.0.1:12345/",
  "token": "replace-with-random-runtime-token"
}
```

| 項目 | 現在のクライアント要件 |
|---|---|
| ファイル | 現在のユーザーが所有する通常ファイル、16 KiB 未満。他ユーザーへの権限は禁止、推奨 `0600` |
| パスの上書き | `AHAKEY_RUNTIME_DISCOVERY` にファイルの絶対パスを設定。WebSocket URL ではない |
| アドレス | `ws://127.0.0.1:port/` または `ws://[::1]:port/`。localhost、リモートアドレス、wss は拒否 |
| URL | ユーザー名、パスワード、query、fragment を含めない。HTTP リダイレクトは拒否 |
| ハンドシェイク | subprotocol の指定や独自 Authorization ヘッダーのない標準 WebSocket |
| 認証 | 最初の runtime.hello の JSON params に token を渡す。URL には含めない |

ディレクトリは `0700` を推奨します。同じディレクトリ内に `0600` の一時ファイルを作成し、完成後に rename して、不完全な JSON の読み取りを防ぎます。再起動でポート/token が変わる場合は更新してください。フロントエンドは再接続ごとに読み直します。同一ユーザーの複数 Runtime がデバイスや discovery を奪い合わないようにしてください。

サーバーは認証前の業務メソッドを拒否し、不正な token にスナップショットを返してはいけません。現在のネイティブクライアントは Origin を明示設定しません。Origin のないネイティブ接続を許可し、未許可のブラウザー Origin は拒否してください。loopback であることだけでは認証になりません。token をログへ記録しないでください。

## 3. WebSocket と JSON-RPC の規則

- WebSocket の**テキストメッセージ一つ**に JSON-RPC 2.0 オブジェクトを一つ格納します。バッチ配列、改行区切りプロトコル、バイナリの業務メッセージは使用しません。
- リクエスト id は文字列で、応答にそのまま返します。RPC id と業務上の operationId は別の識別子です。
- 応答は result と error のどちらか一方だけを含めます。空の result オブジェクトは有効ですが、id だけの応答は無効です。
- 応答の到着順は問いません。イベントは同じ接続内で sequence の昇順に送信します。
- 一メッセージは最大 1 MiB、クライアントの同時実行リクエストは最大 32 件です。
- いずれかのリクエストが **10 秒**以内に応答しないと、接続全体を閉じ、待機中の全リクエストを失敗にします。
- 切断から約 2 秒後に再接続し、hello、完全なスナップショットの購読、基準状態の読み取り、未確定操作の照会を行います。書き込みの自動再送は行いません。

成功応答：

```json
{"jsonrpc":"2.0","id":"request-1","result":{}}
```

業務エラー：

```json
{
  "jsonrpc": "2.0",
  "id": "request-1",
  "error": {
    "code": -32000,
    "message": "Configuration baseline changed",
    "data": {"code": "BASE_CONFLICT"}
  }
}
```

フロントエンドは error.data.code の安定した文字列を使用し、任意の message は表示しません。業務コードがなければ、-32602 は INVALID_PARAMS、-32601 は UNSUPPORTED_CAPABILITY、その他は RPC_ERROR に対応します。

## 4. 認証、購読、デバイス状態

### 4.1 runtime.hello

リクエスト：

```json
{
  "jsonrpc": "2.0",
  "id": "hello-1",
  "method": "runtime.hello",
  "params": {
    "protocol": {"major": 1, "minor": 0},
    "client": {"name": "AhaKey Studio", "version": "0.1.0", "kind": "studio"},
    "token": "replace-with-random-runtime-token"
  }
}
```

応答：

```json
{
  "jsonrpc": "2.0",
  "id": "hello-1",
  "result": {
    "protocol": {"major": 1, "minor": 0},
    "instanceId": "runtime-boot-uuid",
    "runtimeVersion": "0.1.0",
    "methods": [
      "runtime.subscribe", "configuration.get", "configuration.apply",
      "operation.get", "device.connect", "device.disconnect"
    ]
  }
}
```

result の四フィールドはすべて必須です。major は 1 にします。現在は minor による分岐がないため、まず 0 を返してください。methods には実装済みメソッドだけを宣言し、以降の呼び出しはこの一覧で制限されます。runtime.subscribe がないと接続を確立できません。runtime.hello は初期接続用なので、自分自身を一覧に含める必要はありません。

### 4.2 runtime.subscribe

リクエスト：

```json
{"jsonrpc":"2.0","id":"sub-1","method":"runtime.subscribe","params":{"topics":["state"],"cursor":null}}
```

応答：

```json
{
  "jsonrpc": "2.0",
  "id": "sub-1",
  "result": {
    "subscriptionId": "subscription-uuid",
    "snapshot": {
      "instanceId": "runtime-boot-uuid",
      "sequence": "100",
      "devices": [{
        "deviceId": "x1-stable-id",
        "name": "AhaKey X1",
        "connectionState": "ready",
        "batteryPercent": 82,
        "workMode": 0,
        "lever": "manual"
      }],
      "operations": []
    }
  }
}
```

snapshot の四フィールドはすべて必須で、空の配列は `[]` にします。instanceId は hello と一致させ、subscriptionId で購読を識別します。deviceId はスキャンごとに再生成せず、安定した識別子にします。

**購読登録とスナップショット取得は、同じ整合性境界で行ってください。** 状態を直列化する処理内で購読を登録し、sequence=N のスナップショットを取得して応答を送信キューに入れ、その後に N より新しいイベントを送ります。スナップショットを読んでから遅れて登録すると、その間のイベントが失われます。ネットワーク送信や BLE を待つ間、状態ロックを保持しないでください。

クライアントごとに送信キューと subscriptionId を持ち、認証済みの全購読者へ変更を配信します。現在は常に cursor:null を送るため、今回の接続に過去イベントの再生は不要です。

### 4.3 runtime.event

イベントは id のない通知です。

```json
{
  "jsonrpc": "2.0",
  "method": "runtime.event",
  "params": {
    "subscriptionId": "subscription-uuid",
    "instanceId": "runtime-boot-uuid",
    "sequence": "101",
    "type": "device.changed",
    "data": {
      "deviceId": "x1-stable-id",
      "name": "AhaKey X1",
      "connectionState": "ready",
      "batteryPercent": 81,
      "workMode": 0,
      "lever": "automatic"
    }
  }
}
```

| type | data | フロントエンドの処理 |
|---|---|---|
| `device.changed` | 完全な Device オブジェクト | デバイスの表示状態を更新 |
| `operation.changed` | 完全な Operation。第 6 節を参照 | 進捗・終了状態を更新し、未確定操作の追跡を終了 |
| `configuration.changed` | 少なくとも `{"deviceId":"x1-stable-id"}` | 対象デバイスの基準状態を無効化 |
| `configuration.invalidated` | 少なくとも `{"deviceId":"x1-stable-id"}` | 対象デバイスの基準状態を無効化 |

イベント params の五フィールドはすべて必須です。sequence は `"9007199254740993"` のような **UInt64 範囲の十進文字列**で、JSON number にはしません。Rust 内部では u64 を使い、送信時に文字列へ変換できます。同一 instance 内では単調増加とし、フィルターによる欠番は許容します。再起動で instanceId が変われば sequence をリセットできます。

クライアントは古い instance、subscription、適用済み以下の sequence を無視します。購読応答の引き継ぎ中は最大 256 イベントを保持します。複数タスクの並行送信で新しいイベントが先に届かないようにしてください。

### 4.4 Device と接続メソッド

| フィールド | 型 | 意味 |
|---|---|---|
| `deviceId` / `name` | 必須 string | 安定したデバイス識別子 / 表示名 |
| `connectionState` | 必須 string | **ready のときだけ保存可能**。接続中は connecting、切断時は disconnected を使用できる |
| `batteryPercent` | 省略可能な integer または null | 0–100。不明は null とし、0 で代用しない |
| `workMode` | 省略可能な integer または null | 判明していれば 0–3。デバイスの実際のモード |
| `lever` | 省略可能な string または null | automatic / manual。不明は null。旧仕様の up/down 数値は使わない |

接続リクエスト：

```json
{"jsonrpc":"2.0","id":"connect-1","method":"device.connect","params":{"deviceId":"x1-stable-id"}}
```

切断は同じ params で device.disconnect を呼びます。どちらも result:{} を返せます。UI は device.changed を待って更新します。要求の成功はデバイスの ready を意味しません。明示的なスキャンメソッドはなく、Runtime が自らデバイスを探索します。

UI は配列の先頭デバイスのみ使用し、更新で配列順が変わる場合があります。初回の接続検証では対象一台だけを公開してください。device.removed の処理はありません。デバイスが消えた場合、まず disconnected の状態を配信し、次のスナップショットで一覧を更新します。

## 5. 設定の基準状態と書き込み

### 5.1 configuration.get

リクエスト：

```json
{"jsonrpc":"2.0","id":"get-1","method":"configuration.get","params":{"deviceId":"x1-stable-id"}}
```

完全な result は [configuration.json](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/contracts/runtime-v1/fixtures/configuration.json) を参照してください。deviceId、baseToken、configuration を含みます。baseToken は不透明な文字列で、クライアントがそのまま返します。数値変換しないでください。再起動後に古い token が偶然有効にならないよう、デバイス状態の世代と設定リビジョンを区別できる形式を推奨します。

信頼できる基準状態を確立できない場合：

```json
{
  "jsonrpc": "2.0",
  "id": "get-1",
  "result": {
    "deviceId": "x1-stable-id",
    "baseToken": "unknown-generation-1",
    "configuration": null
  }
}
```

**実機の初期設定は、事前に解決すべき条件です。** configuration:null では保存が無効になり、現在の UI に強制初期化ボタンはありません。ファームウェアから全キー/灯設定を読み戻せない場合、ソフトウェアの既定値を確認済みのデバイス状態として返してはいけません。Rust 側で明示的な初期設定と確認を済ませ、確認済み設定を永続化するか、今後フロントエンドと仕様を拡張し、ユーザーが明示的に初期化できるようにします。書き込み予定値、古いキャッシュ、接続成功だけでは現在の設定を証明できません。

この仕様にはフィールド単位の根拠を表すモデルがありません。初回検証では四モードすべてと全体の明るさを確認できたときに完全な設定を返し、不明なら null にしてください。Schema は 1–4 モードを許可しますが、UI は configuration が非 null かどうかしか判定しないため、実際の書き込み範囲に安全な基準状態があるかはバックエンドで検証する必要があります。

基準状態を読み取っても、編集中のドラフトはデバイス設定に置き換わりません。その後の保存では、選択した範囲をローカルドラフトで上書きします。configuration.get を「ドラフトを置き換える同期」と解釈しないでください。

### 5.2 configuration.apply

完全な params は [apply.json](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/contracts/runtime-v1/fixtures/apply.json) にあります。次のスクリプトで完全な JSON-RPC リクエストを生成できます。deviceId/baseToken は実際の get 結果に置き換えてください。

```sh
python3 - <<'PY'
import json
from pathlib import Path
params = json.loads(Path("contracts/runtime-v1/fixtures/apply.json").read_text())
print(json.dumps({"jsonrpc": "2.0", "id": "apply-1",
                  "method": "configuration.apply", "params": params}, indent=2))
PY
```

| params フィールド | 意味 |
|---|---|
| `operationId` | 送信前にフロントエンドが生成・保存する UUID。冪等性キー |
| `deviceId` | 対象デバイス |
| `baseToken` | 直近に取得した基準状態の token |
| `scope.deviceFields` | 現在は常に `["brightnessPercent"]` |
| `scope.modes` | 選択モード `[0]` など、または全モード `[0,1,2,3]` |
| `changes.device` | `{"brightnessPercent":60}`。範囲は **1–100** |
| `changes.modes` | 選択した各モードの完全な keys と lights。差分ではない |

一モードの保存でも**デバイス全体の明るさ**を送ります。バックエンドは scope 内だけを置き換え、他のモードを保持します。changes をデバイス全体の設定として丸ごと置換しないでください。scope と changes を一致させ、mode、role、state の重複を禁止します。

各モードは `{"mode":0,"keys":[四つのキー],"lights":[九つの対応付け]}` です。role は voice、approve、reject、submit の四種類を一つずつ含めます。各キーの role、action、description は必須です。description は最大 20 バイトの ASCII で、空文字列も許可します。

action は次の三形式から一つを選びます。

```json
[
  {"type":"disabled"},
  {"type":"shortcut","modifiers":["control","shift","alt","gui"],"keyCode":40},
  {"type":"macro","steps":[
    {"type":"keyDown","keyCode":40},
    {"type":"delay","delayMs":15},
    {"type":"keyUp","keyCode":40},
    {"type":"releaseAll"},
    {"type":"noOp"}
  ]}
]
```

上の配列は三つの候補を並べた例で、RPC バッチではありません。type フィールドを持つ内部タグ形式にし、Rust の既定の外部タグ `{"Shortcut":{...}}` は使いません。gui は Command、alt は Option に対応します。keyCode は 0–255 の HID usage で、keyCode=0 の修飾キーのみの組み合わせを捨てないでください。

マクロは 1–49 ステップです。delayMs は 0–765 ミリ秒、3 の倍数です。通信では常にミリ秒を使い、ファームウェアの tick 変換は Rust のデバイス層で行います。引数のないステップは type のみ、keyDown/keyUp は keyCode、delay は delayMs を持ちます。

灯の対応付けは `{"state":"notification","effect":"pulseCenter"}` 形式です。辞書やファームウェアの数値番号ではありません。

| 項目 | 許可される値 |
|---|---|
| 九つの state | `notification`, `permissionRequest`, `postToolUse`, `preToolUse`, `sessionStart`, `stop`, `taskCompleted`, `userPromptSubmit`, `sessionEnd` |
| 十七の effect | `off`, `middleLight`, `singleMove`, `breathing`, `rainbowMove`, `rainbowWave`, `rainbowWaveSlow`, `typingRipple`, `comet`, `scanBar`, `pulseCenter`, `warningBlink`, `successSweep`, `blueThinking`, `lowBattery`, `chargingFlow`, `approvalWait` |

### 5.3 受理とデバイス書き込みの順序

デバイス別の直列キュー/状態 actor で処理します。新規要求の基準状態チェックより先に operationId の重複を調べます。

```text
認証・リクエスト解析
→ operationId を検索
  → 同じ ID・同じ業務要求：元の受理情報を返し、再書き込みしない
  → 同じ ID・異なる要求：OPERATION_ID_CONFLICT
→ デバイス、scope、完全な書き込みグループ、値域、baseToken を検証
→ デバイス書き込み権をアトミックに確保し、操作を永続化
→ 作業をキューへ入れ、accepted を応答
→ BLE コマンドと確認を非同期実行し、running/progress を通知
→ 信頼できる設定と新 baseToken を確定し、操作の終了状態を永続化
→ configuration.changed の後に operation.changed(completed) を通知
```

受理応答の operationId はリクエストと一致させます。

```json
{"jsonrpc":"2.0","id":"apply-1","result":{"operationId":"example-operation","status":"accepted"}}
```

バックエンドが継続して操作を追跡できる状態になってから accepted を返します。全 BLE 書き込みの完了を待ってはいけません。同時要求はキューで待機させるか、受理前に BUSY を返せます。ただし基準状態の検証と書き込み権の確保の間に競合を作らないでください。冪等性は解析済みの業務内容で比較し、JSON のキー順や空白に依存しないようにします。

デバイス層は shortcut/macro の相互クリア、説明・灯のエンコード、明るさ、ファームウェアの保存処理、確認条件を担当します。BLE ライブラリへ bytes を渡しただけでは完了とは言えません。一部書き込み後に失敗した場合は旧基準状態を無効にし、ロールバック済みと偽ってはいけません。

## 6. 操作照会、進捗、失敗

照会リクエストと応答：

```json
{"jsonrpc":"2.0","id":"op-1","method":"operation.get","params":{"operationId":"example-operation"}}
```

```json
{
  "jsonrpc": "2.0",
  "id": "op-1",
  "result": {
    "operationId": "example-operation",
    "deviceId": "x1-stable-id",
    "status": "completed",
    "progress": 1.0,
    "effect": "complete",
    "errorCode": null
  }
}
```

operationId/deviceId/status は必須です。progress/effect/errorCode は省略または null が可能です。progress は 0–1 の数値です。同じ構造を snapshot.operations と operation.changed の data に使用します。

| status | 推奨 effect | 意味 |
|---|---|---|
| `accepted` | `none` | 受理済み、デバイス変更は未確認 |
| `running` | 根拠に応じて partial または unknown | 実行中 |
| `completed` | `complete` | 全要件を確認し、基準状態を更新済み |
| `failed` | none / partial / unknown | 失敗。errorCode で理由を示す |
| `cancelled` | none / partial / unknown | バックエンドが操作を終了。現在の UI にキャンセル RPC はない |

部分的な失敗の完全な通知例：

```json
{
  "jsonrpc": "2.0",
  "method": "runtime.event",
  "params": {
    "subscriptionId": "subscription-uuid",
    "instanceId": "runtime-boot-uuid",
    "sequence": "102",
    "type": "operation.changed",
    "data": {
      "operationId": "example-operation",
      "deviceId": "x1-stable-id",
      "status": "failed",
      "progress": 0.5,
      "errorCode": "DEVICE_TIMEOUT",
      "effect": "partial"
    }
  }
}
```

受理後のハードウェア障害は Operation に記録してイベントで通知します。一時的な RPC error だけを返して操作を捨ててはいけません。クライアントが終了状態として認識するのは completed、failed、cancelled です。success/done/error に置き換えないでください。

### 6.1 エラーコードと受理の有無

| 安定したコード | 使用条件 | 現在のフロントエンド動作 |
|---|---|---|
| `BASE_CONFLICT` | 受理前に token の失効を検出 | 未確定要求を除去し、基準状態の再読み取りを要求 |
| `BUSY` | 受理前にデバイスキューへ投入できない | 同上 |
| `DEVICE_NOT_READY` | 受理前にデバイスが未準備 | 同上 |
| `INVALID_PARAMS` | 受理前の不正パラメーター | 同上 |
| `UNSUPPORTED_CAPABILITY` | 受理前に未対応機能を検出 | 同上 |
| `INCOMPLETE_WRITE_GROUP` | 受理前に必要な設定グループの不足を検出 | 同上 |
| `OPERATION_ID_CONFLICT` | 同じ ID に異なる要求 | 未書き込みとは判断せず、追跡・照会を続ける |
| `OPERATION_NOT_FOUND` | 過去の操作を検索できない | 結果不明を表示し、未確定状態を維持 |
| `DEVICE_TIMEOUT` など | 受理済み操作の errorCode | failed Operation で追跡を終了し、書き込み可能な基準状態を無効化 |

**先頭六つは、フロントエンドが「確実に未受理」と判断する固定の許可リストです。** 受理後の失敗に使用してはいけません。別の受理前拒否コードを追加する場合はフロントエンドも更新してください。更新しなければ未確定操作を保持して照会し続けます。

### 6.2 永続化と再起動時の復元

フロントエンドは送信前に元の apply と operationId を保存します。受理応答の消失や Runtime 再起動後は同じ ID を照会し、新しい ID を作って自動再送しません。サーバーは要求の識別情報、操作状態、デバイスへの影響、設定リビジョンを永続化する必要があります。

操作記録は WebSocket 切断後も保持し、本番 Runtime はプロセス再起動後にも復元してください。保存期間はバックエンドで明示的に定めます。現行仕様に固定の日数はありません。期限切れなら OPERATION_NOT_FOUND を返し、「記録がない」を「実行していない証拠」と解釈しないでください。

再起動時に実行中だった操作は、実機で検証できる事実から照会を復元するか、failed/unknown として終了し、設定を無効化します。根拠なく書き込み全体を再実行しないでください。ユーザーが不明な結果を確認して追跡を終了した後も、次の保存には信頼できる基準状態の再取得が必要です。

## 7. Rust の責務分担とシリアライズ

推奨する分割です。既存 Rust コードの名前変更を要求するものではありません。

| モジュール | 責務 |
|---|---|
| `ipc/discovery` | 待ち受けアドレス、非公開 token ファイル、アトミック更新 |
| `ipc/session` | WebSocket、認証状態、JSON-RPC 振り分け、接続別送信キュー |
| `ipc/wire` | Schema と一致する DTO、安定したエラーコード |
| `runtime/state` | スナップショット、単調増加 sequence、購読登録、配信 |
| `runtime/configuration` | 信頼できる基準状態、baseToken、範囲検証、設定リビジョン |
| `runtime/operations` | 冪等性索引、永続化、照会、デバイス別実行 |
| `device/*` | BLE/ファームウェア仕様、ACK、タイムアウト、状態の根拠 |

BLE struct やデータベースレコードをそのまま IPC DTO にしないでください。Rust の snake_case フィールドは、通信時に仕様どおりの camelCase にします。action と macro step は type による内部タグ形式です。Serde を使う場合は variant とフィールドの通信名を明示し、特に keyDown/keyUp/releaseAll/noOp/keyCode/delayMs を確認してください。

sequence の通信 DTO は文字列とし、内部では u64 として検証します。baseToken/operationId/deviceId は不透明な文字列です。optional フィールドは null または省略を許可しますが、必須配列は null にしません。解析後に role/state の一意性、scope の整合性、実機の制限を検証します。

ローカルパス、Flash アドレス、RGB565、BLE パケット番号、UI の翻訳文を設定インターフェースに入れないでください。選択した GIF は Studio 内に保存され、Rust へアップロードされません。

## 8. 接続検証の手順

### 8.1 既存 fixture でフロントエンドを確認

Studio リポジトリのルートで実行します。

```sh
python3 scripts/mock-runtime-server.py
```

stdout に一時 discovery ファイルのパスが出力されます。Xcode で **Studio Frontend** を選び、Edit Scheme → Run → Arguments → Environment Variables に設定します。

```text
AHAKEY_RUNTIME_DISCOVERY = 上で出力された絶対パス
```

起動後、状態表示、明るさ変更、保存、completed を確認します。この Python サービスはプロトコル fixture であり、実 BLE、本番用永続化、完全な複数クライアント配信は含みません。

### 8.2 Rust サービスへ切り替え

1. 旧 AhaKey Studio/旧デバイスバックエンドを終了し、対象デバイスを Rust だけが管理する状態にします。
2. Rust を起動して、規定の discovery ファイルを公開します。
3. Xcode の環境変数を Rust のファイルへ変更します。既定パスを使う場合はテスト用の上書きを削除します。
4. **Studio Frontend** を使用します。**Studio Frontend Mock** は WebSocket を使いません。
5. hello → subscribe → configuration.get の成功を確認し、ready と信頼できる基準状態が揃ったら一度保存します。
6. Rust の操作ログと実機の結果を照合します。completed 後の get は新しい baseToken を返す必要があります。
7. 保存中に WebSocket を切断して再接続し、operation.get が元の操作を復元し、BLE 書き込みを重複実行しないことを確認します。

ビルド後に shell から直接起動すると、環境変数をプロセスへ渡せます。

```sh
AHAKEY_RUNTIME_DISCOVERY="/absolute/path/to/discovery.json" \
  "DerivedData/Frontend/Build/Products/Debug/Studio Frontend.app/Contents/MacOS/Studio Frontend"
```

### 8.3 自動検証と受け入れ条件

Studio リポジトリのルートで既存のフロントエンドテストを実行します。

```sh
xcodebuild -project "AhaKey Studio.xcodeproj" -scheme "Studio Frontend" \
  -configuration Debug -destination "platform=macOS,arch=arm64" \
  -derivedDataPath DerivedData/Frontend \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual test
```

Intel Mac では arch=x86_64 を使用します。既存の WebSocket テストは Python fixture を自動起動し、**実行中の Rust サービスへ自動で接続先を変更しません**。Rust の結合テストを追加するか、次の条件を確認してください。

| 検証項目 | 必要な結果 |
|---|---|
| 不正 token / hello 前の業務メソッド | 状態を漏らさず拒否 |
| 既存四つの fixture | Rust が解析でき、再シリアライズ後も構造とフィールドの意味が一致 |
| JS 安全整数を超える sequence | 9007199254740993 を浮動小数点の丸めなしに保持 |
| スナップショット引き継ぎ中の変化 | イベント欠落がなく、クライアントの最終状態が正しい |
| 一モード保存 | 対象モードと全体の明るさのみ更新し、他モードを保持 |
| 同一 ID・同一要求の再呼び出し | 元の受理情報を返し、実機実行は一度のみ |
| 同一 ID・異なる要求 | OPERATION_ID_CONFLICT、元の操作を保持 |
| 外部変更後に古い token で保存 | BASE_CONFLICT、追加の実機書き込みなし |
| 保存中の切断 / 受理応答消失 | 元の operationId を照会可能、自動再送なし |
| BLE 書き込み途中の失敗 | failed + partial/unknown、旧基準状態を無効化 |
| 実行中の Runtime 再起動 | 新 instanceId、操作を復元するか不明と報告し、盲目的に再実行しない |
| 二つの購読クライアント | 各購読 ID で両方に変更イベントが届く |
| 読み戻せない新品デバイス | configuration=null、明示的な初期化後に保存可能になる |

[schema.json](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/contracts/runtime-v1/schema.json) は現在 `$defs` のみで、ルート `$ref` がありません。fixture の検証では対応する定義を選んでください。ファイル全体をルートに指定するだけでは制約が適用されません。対応は hello.json → Hello、subscription.json → Subscription、configuration.json → ConfigurationDocument、apply.json → Apply です。一意性、完全な書き込みグループ、冪等性、並行実行は Rust の業務テストでも検証します。

## 9. 現在の制限とトラブルシューティング

| 症状 | 最初に確認する点 |
|---|---|
| 常にオフライン | discovery パス、owner/0600、loopback IP、待ち受け、token、major=1、methods に runtime.subscribe があるか |
| 約 10 秒で切断 | BLE が RPC をブロックしていないか、accepted が遅くないか、id を正確に返しているか |
| デバイスは表示されるが保存不可 | ready、非 null configuration、未確定操作、外部変更、ドラフト検証、apply の宣言 |
| イベントが反映されない | runtime.event、instanceId/subscriptionId 一致、増加する文字列 sequence、完全な data |
| 保存後も基準状態が無効 | 新基準状態を先に確定し、configuration.changed を completed より前に通知する。後着イベントによる get の無効化を防ぐ |
| 結果不明 | operation.get に元の ID があるか。永続化、再起動復元、保存期間を確認 |

自動的な基準状態の取得は、Runtime セッション確立後と自身の操作が completed になった後だけです。起動時に一覧が空で、後からデバイスが現れる/ready になる場合や、外部 configuration.changed の受信後は、ユーザーが基準状態を再読み取りする必要があります。これらの自動更新は未実装です。ready や既定設定を偽って回避しないでください。

OLED/GIF アップロード、実機の灯プレビュー、Hook 管理、音声ホスト、テキスト入力、ファームウェア書き込み、複数デバイス選択、実機モード切り替え、部分的に不明なフィールドへの書き込みは未対応です。編集モードタブはドラフトの編集範囲だけを変えます。機能追加にはフロントエンド、Rust、fixture の対応を揃える必要があり、methods への宣言だけで UI は追加されません。

## 10. 関連コード

- [プロトコル概要](../../contracts/runtime-v1/README.ja.md) と [JSON Schema](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/contracts/runtime-v1/schema.json)
- [Swift 通信 DTO](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/StudioFrontend/Runtime/RuntimeDTOs.swift) と [WebSocket クライアント](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/StudioFrontend/Runtime/IPCRuntimeClient.swift)
- [購読・イベントの状態反映](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/StudioFrontend/State/RuntimeStore.swift) と [保存・復元処理](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/StudioFrontend/State/StudioModel.swift)
- [ドラフトから通信設定への変換](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/StudioFrontend/State/StudioDraftStore.swift)
- [Python WebSocket fixture](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/scripts/mock-runtime-server.py) と [フロントエンドテスト](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/Tests/StudioFrontendTests/RuntimeTests.swift)
- [旧デバイスプロトコル](../ble-protocol.md) と [旧ファームウェア形式](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/AhaKey%20Studio/Services/Bluetooth/LegacyDraftEncoding.swift)。デバイスアダプターの参考用
