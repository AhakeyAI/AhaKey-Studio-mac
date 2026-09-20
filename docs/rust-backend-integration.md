# Rust Runtime 对接 Studio 开发文档

本文对应本仓库本地 `dev` 分支的 **Studio Frontend** target，协议版本 `1.0`。目标是让 Rust Runtime 接管设备连接、状态和配置写入，现有 SwiftUI 前端通过本机 WebSocket 调用它。本文描述已实现的客户端行为；Rust 服务与真机闭环尚未验证。

接口字段以 [RuntimeDTOs.swift](../StudioFrontend/Runtime/RuntimeDTOs.swift)、[IPCRuntimeClient.swift](../StudioFrontend/Runtime/IPCRuntimeClient.swift) 和 [协议样例](../contracts/runtime-v1/fixtures/) 为准。早期 `runtime-studio-*.md` 文档含更广的规划，不能直接当作当前客户端接口。

## 1. 需要实现什么

实现一个独立运行、由当前用户启动的 Rust 进程，提供以下七个方法：

| 方法 | 用途 | 返回时机 |
|---|---|---|
| `runtime.hello` | token 认证、协议协商、能力声明 | 完成认证后立即返回 |
| `runtime.subscribe` | 注册状态订阅并返回一致快照 | 订阅建立后立即返回 |
| `configuration.get` | 获取配置基线和版本 token | 从可信状态读取，避免等待长时间设备扫描 |
| `configuration.apply` | 校验并受理配置操作 | 记录操作后返回 `accepted`，设备写入异步执行 |
| `operation.get` | 查询原操作，恢复丢失的结果 | 从操作记录读取 |
| `device.connect` | 请求连接指定设备 | 请求入队后返回，连接结果通过事件推送 |
| `device.disconnect` | 请求断开指定设备 | 请求入队后返回，状态通过事件推送 |

前三个方法即可验证连接和读取；完整保存闭环需要 `configuration.apply`、`operation.get` 和状态事件。当前前端不会启动 Runtime，也不会回退到旧版 Swift 蓝牙后台。退出 Studio 只关闭 WebSocket，不停止 Runtime、不取消已受理操作。

```text
Studio Frontend
  └─ 本机 WebSocket / JSON-RPC 2.0
       └─ Rust：认证、订阅、配置基线、操作记录、每设备写入队列
            └─ Rust 设备适配层：BLE、固件编码、ACK、超时与状态读取
                 └─ AhaKey X1
```

## 2. 启动与 discovery 配置

Runtime 推荐按以下顺序启动：

1. 恢复配置与操作记录；每次进程启动生成新的 `instanceId`。
2. 只监听 `127.0.0.1` 或 `::1`，可使用系统分配的空闲端口。
3. 生成不可预测的会话 token；在监听成功后，原子写入 discovery 文件。
4. 启动设备发现与状态维护。扫描没有完成时允许快照返回空设备列表。

默认 discovery 路径：

```text
~/Library/Application Support/AhaKey/runtime/discovery.json
```

文件内容示例，端口和 token 必须替换为实际值：

```json
{
  "endpoint": "ws://127.0.0.1:12345/",
  "token": "replace-with-random-runtime-token"
}
```

| 项目 | 当前客户端要求 |
|---|---|
| 文件 | 当前用户拥有的普通文件，小于 16 KiB；其他用户不得有任何权限，推荐 `0600` |
| 覆盖路径 | 环境变量 `AHAKEY_RUNTIME_DISCOVERY`，值为文件的绝对路径，不是 WebSocket URL |
| 地址 | `ws://127.0.0.1:端口/` 或 `ws://[::1]:端口/`；`localhost`、远端地址、`wss` 不被接受 |
| URL | 不含用户名、密码、query、fragment；客户端拒绝 HTTP 重定向 |
| 握手 | 普通 WebSocket，无指定 subprotocol，无自定义 Authorization 头 |
| 认证 | token 放在第一条 `runtime.hello` 的 JSON params 内，不放 URL |

建议目录权限 `0700`；使用同目录临时文件以 `0600` 创建，再 rename 到目标路径，避免客户端读到半份 JSON。重启更换端口/token 后更新文件，前端每次重连都会重新读取。应防止同一用户意外启动两个 Runtime 同时争抢设备或覆盖 discovery。

Rust 服务端必须在认证前拒绝其他业务调用，错误 token 不得得到设备快照。当前原生客户端不主动设置 Origin；服务端需允许原生无 Origin 的连接，并拒绝非授权浏览器 Origin，不能仅依靠 loopback 地址代替认证。不要在日志中记录 token。

## 3. WebSocket 与 JSON-RPC 规则

- 一个 WebSocket **文本消息**对应一个 JSON-RPC 2.0 对象，不使用批量数组、换行分隔协议或二进制业务消息。
- 请求 `id` 是字符串；响应原样返回。RPC `id` 与业务 `operationId` 是两个不同标识。
- 响应恰好包含 `result` 或 `error` 之一；成功结果可以是空对象，不能只有 `id`。
- 客户端接受响应乱序；同一连接上的事件必须按递增序号发送。
- 单条消息上限 1 MiB，客户端最多 32 个在途请求。
- 任一请求超过 **10 秒**未返回，客户端关闭整条连接，所有在途请求失败。
- 断线后约 2 秒重连，重新 hello、订阅完整快照、读取基线、查询未决操作；没有自动重发写请求。

成功响应：

```json
{"jsonrpc":"2.0","id":"request-1","result":{}}
```

业务错误：

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

前端使用 `error.data.code` 的稳定字符串，不展示任意 `message`。没有业务码时，`-32602` 映射到 `INVALID_PARAMS`，`-32601` 映射到 `UNSUPPORTED_CAPABILITY`，其他错误映射到 `RPC_ERROR`。

## 4. 认证、订阅与设备状态

### 4.1 runtime.hello

请求：

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

响应：

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

上述四个 result 字段全部必需。`major` 必须为 `1`；当前客户端不按 minor 分支，先返回 `0`。`methods` 只列真实支持的方法；后续调用受该列表约束。漏掉 `runtime.subscribe` 会直接导致连接建立失败。`runtime.hello` 是引导方法，无需把自己列入列表。

### 4.2 runtime.subscribe

请求：

```json
{"jsonrpc":"2.0","id":"sub-1","method":"runtime.subscribe","params":{"topics":["state"],"cursor":null}}
```

响应：

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

`snapshot` 的四个字段全部必需；空列表使用 `[]`。`instanceId` 与 hello 相同；`subscriptionId` 区分订阅；设备 ID 应保持稳定，不能每次扫描重新生成。

**订阅与快照必须具有一致边界**：在同一状态串行化边界内注册订阅并读取序号为 N 的快照，将响应先放入该连接的发送队列，再发送 N 之后的事件。不要先读快照、过一会儿才注册订阅，否则中间事件会丢失。不要持锁等待网络发送或 BLE。

每个客户端拥有自己的发送队列和 subscriptionId；状态改变需要广播给所有已认证且订阅的客户端。当前前端始终传 `cursor:null`，无需为此次接入实现历史事件重放。

### 4.3 runtime.event

事件是无 `id` 的通知：

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

| type | data | 前端处理 |
|---|---|---|
| `device.changed` | 完整 Device 对象 | 更新设备投影 |
| `operation.changed` | 完整 Operation 对象，见第 6 节 | 更新进度及终态，结束本地未决跟踪 |
| `configuration.changed` | 至少 `{"deviceId":"x1-stable-id"}` | 将该设备基线标记为失效 |
| `configuration.invalidated` | 至少 `{"deviceId":"x1-stable-id"}` | 将该设备基线标记为失效 |

事件 params 的五个字段均必需。`sequence` 必须是 **UInt64 范围的十进制字符串**，例如 `"9007199254740993"`；不能发送 JSON number。Runtime 可在内存用 `u64`，出站转字符串。同一实例单调递增，允许因过滤产生间隙；重启更换 instanceId 后可重置序号。

客户端忽略旧实例、旧订阅和不大于已应用序号的事件；订阅交接期间最多缓冲 256 条事件。不要因多个任务并发发送而将较新事件排到较旧事件之前。

### 4.4 Device 与连接方法

| 字段 | 类型 | 语义 |
|---|---|---|
| `deviceId` / `name` | string，必需 | 稳定设备标识 / 显示名 |
| `connectionState` | string，必需 | **只有 `ready` 允许保存**；连接未完成可用 `connecting`，断开可用 `disconnected` |
| `batteryPercent` | integer 或 null，可省略 | 0–100；未知用 null，不能冒充 0 |
| `workMode` | integer 或 null，可省略 | 已知时为 0–3；这是设备当前模式 |
| `lever` | string 或 null，可省略 | `automatic` / `manual`；未知用 null，不使用旧协议的 up/down 数值 |

连接请求示例：

```json
{"jsonrpc":"2.0","id":"connect-1","method":"device.connect","params":{"deviceId":"x1-stable-id"}}
```

断开使用相同 params 和 `device.disconnect`。两者可以返回 `result:{}`；前端等待 `device.changed` 更新 UI。请求成功不等于设备已经 ready。当前没有主动扫描方法，由 Runtime 自行发现设备并发布状态。

当前 UI 只使用设备数组中的第一台，且设备更新可能改变数组顺序，因此首轮联调应只暴露一台目标设备。没有 `device.removed` 处理器；运行期间设备消失时先发布其 `disconnected` 投影，下一次快照再更新列表。

## 5. 配置基线与配置提交

### 5.1 configuration.get

请求：

```json
{"jsonrpc":"2.0","id":"get-1","method":"configuration.get","params":{"deviceId":"x1-stable-id"}}
```

result 的完整样例见 [configuration.json](../contracts/runtime-v1/fixtures/configuration.json)。其结构为 `deviceId`、`baseToken`、`configuration`。`baseToken` 是不透明字符串，前端原样回传，不能转为数字。建议用能区分设备状态世代和配置修订的 token，避免重启后旧 token 意外重新有效。

如果无法建立可信配置基线，应返回：

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

**首次真机初始化是必须处理的前置条件。** 当前 UI 在 `configuration:null` 时禁止保存，没有“强制初始化设备”的按钮。若固件不能回读完整键位/灯效，不能把软件默认值包装成已知设备事实。可在 Rust 侧先完成显式初始化和确认，建立持久化的已确认配置记录；或后续扩展前端与协议，允许用户明确执行初始化。仅持有计划写入的配置、旧缓存或连接成功，都不足以证明设备当前配置已知。

当前协议没有字段级证据模型。首次联调建议在全部四个模式和全局亮度均可确认时返回完整配置；无法确认时返回 null。Schema 允许 1–4 个模式，但前端的保存门槛仅检查 configuration 非空，后端仍须校验实际覆盖范围是否具备安全的基线。

读取基线不会把设备配置自动装入本地编辑草稿。用户读取新基线后再次保存，会以本地草稿覆盖选定范围；不要把 `configuration.get` 理解为“同步并替换前端草稿”。

### 5.2 configuration.apply

完整 params 见 [apply.json](../contracts/runtime-v1/fixtures/apply.json)。可用下面的脚本生成一份完整 JSON-RPC 请求，示例 deviceId/baseToken 需要换成实际 get 的结果：

```sh
python3 - <<'PY'
import json
from pathlib import Path
params = json.loads(Path("contracts/runtime-v1/fixtures/apply.json").read_text())
print(json.dumps({"jsonrpc": "2.0", "id": "apply-1",
                  "method": "configuration.apply", "params": params}, indent=2))
PY
```

| params 字段 | 含义 |
|---|---|
| `operationId` | 前端生成并在发送前保存的 UUID；幂等键 |
| `deviceId` | 目标设备 |
| `baseToken` | 最近取得的配置基线 token |
| `scope.deviceFields` | 当前总是 `["brightnessPercent"]` |
| `scope.modes` | 保存当前模式如 `[0]`，或全部 `[0,1,2,3]` |
| `changes.device` | `{"brightnessPercent":60}`；范围 **1–100** |
| `changes.modes` | 所选每个模式的完整 keys 和 lights，不是差量 |

保存单个模式也会提交**全局亮度**。后端只替换 scope 覆盖的字段和模式，其他模式保持原值；不要把 changes 当作整个设备配置直接替换。scope 与 changes 必须一致，不允许重复 mode、role 或 state。

每个模式结构：`{"mode":0,"keys":[四个键],"lights":[九项映射]}`。

键位角色恰好为 `voice`、`approve`、`reject`、`submit`。每个键必须有 `role`、`action`、`description`；description 是最多 20 字节的 ASCII 字符串，允许空串。

action 的三个互斥形状：

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

上方数组仅用于并列展示三个 action 示例，不是 RPC 批量请求。使用带 `type` 字段的内部标签结构，不能输出 Rust 默认外部标签如 `{"Shortcut":{...}}`。`gui` 对应 Command，`alt` 对应 Option。keyCode 是 HID usage，范围 0–255；带修饰键且 keyCode=0 的组合不能被错误丢弃。

宏为 1–49 步；delayMs 是 0–765 毫秒且为 3 的倍数。协议始终传毫秒，固件 tick 编码留在 Rust 设备适配层。无参步骤只传 type；keyDown/keyUp 带 keyCode；delay 带 delayMs。

每个灯效映射为 `{"state":"notification","effect":"pulseCenter"}`，不是字典或固件数字编号。

| 项目 | 可用值 |
|---|---|
| 九种 state | `notification`, `permissionRequest`, `postToolUse`, `preToolUse`, `sessionStart`, `stop`, `taskCompleted`, `userPromptSubmit`, `sessionEnd` |
| 十七种 effect | `off`, `middleLight`, `singleMove`, `breathing`, `rainbowMove`, `rainbowWave`, `rainbowWaveSlow`, `typingRipple`, `comet`, `scanBar`, `pulseCenter`, `warningBlink`, `successSweep`, `blueThinking`, `lowBattery`, `chargingFlow`, `approvalWait` |

### 5.3 受理与设备写入顺序

建议在每设备串行队列/状态 actor 中实现以下逻辑，幂等查重必须先于新请求的基线检查：

```text
认证、解析请求
→ 查询 operationId 是否已存在
  → 同 ID、相同业务请求：返回原受理信息，不再次写设备
  → 同 ID、不同业务请求：OPERATION_ID_CONFLICT
→ 校验设备、scope、完整写入组、值范围与 baseToken
→ 原子预留该设备写入权并持久化操作记录
→ 将工作入队，返回 accepted
→ 异步执行 BLE 命令与确认，发布 running/progress
→ 提交新的可信配置及 baseToken，持久化操作终态
→ 先发布 configuration.changed，再发布 operation.changed(completed)
```

受理响应的 operationId 必须与请求相同：

```json
{"jsonrpc":"2.0","id":"apply-1","result":{"operationId":"example-operation","status":"accepted"}}
```

只有确认可以由后台继续跟踪后才返回 accepted；不能等全部 BLE 写入结束才响应。并发请求可排队或在受理前返回 `BUSY`，但必须保证基线检查、写入权预留之间没有竞态。幂等比较应基于解析后的业务内容，不依赖 JSON 键顺序或空白。

设备适配层负责 shortcut/macro 互斥清理、描述和灯效编码、全局亮度、固件保存以及确认条件。仅将 bytes 交给 BLE 库，不足以宣告整个配置 completed。部分写入失败时使旧配置基线失效，不能假称设备已回滚。

## 6. 操作查询、进度与失败

查询请求和响应：

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

Operation 中 operationId/deviceId/status 必需，progress/effect/errorCode 可省略或 null。progress 为 0–1 的数字。相同结构也用于快照的 operations 和 `operation.changed` 的 data。

| status | effect 建议值 | 含义 |
|---|---|---|
| `accepted` | `none` | 已受理，未确认设备变更 |
| `running` | `partial` 或 `unknown`，按事实填写 | 正在执行 |
| `completed` | `complete` | 全部要求已确认，配置基线已更新 |
| `failed` | `none` / `partial` / `unknown` | 失败；errorCode 指明原因 |
| `cancelled` | `none` / `partial` / `unknown` | 后端已经结束该操作；当前前端没有取消 RPC |

部分失败的完整通知示例：

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

受理之后发生的硬件失败，应写入 Operation 并发送事件，不能只返回一次 RPC error 然后丢掉操作。`completed`、`failed`、`cancelled` 才是客户端识别的终态，不能替换为 success/done/error。

### 6.1 错误码与是否已经受理

| 稳定码 | 使用条件 | 当前前端行为 |
|---|---|---|
| `BASE_CONFLICT` | 受理前发现 token 失效 | 清除该未决请求，要求重新读取基线 |
| `BUSY` | 受理前设备写队列无法接收 | 同上 |
| `DEVICE_NOT_READY` | 受理前设备未就绪 | 同上 |
| `INVALID_PARAMS` | 受理前参数不合法 | 同上 |
| `UNSUPPORTED_CAPABILITY` | 受理前功能不支持 | 同上 |
| `INCOMPLETE_WRITE_GROUP` | 受理前缺少该范围所需的完整配置组 | 同上 |
| `OPERATION_ID_CONFLICT` | 同 ID 对应不同请求 | 不假设设备未写入，保留跟踪并查询 |
| `OPERATION_NOT_FOUND` | 查询不到历史操作 | 显示结果未知，保留未决状态 |
| `DEVICE_TIMEOUT` 等硬件失败 | 已受理操作的 errorCode | 通过 failed Operation 结束跟踪，使基线不可继续写入 |

**前六个码是前端明确认定“尚未受理”的固定白名单。** 不能用它们报告受理后失败。新增其他受理前拒绝码时，需要同步修改前端处理；否则前端会保留未决操作，继续查询结果。

### 6.2 持久化与重启恢复

前端发送前保存原始 apply 和 operationId。受理响应丢失或 Runtime 重启后，前端查询同一个 ID；不会另造 ID 自动再写一次。服务端因此需要持久化请求身份、操作状态、设备变更结果与配置修订。

操作记录必须跨 WebSocket 断开保留；生产 Runtime 应跨进程重启恢复。具体保留期限需要后端明确制定，目前 wire 协议没有固定天数。超过保留期的查询只能返回 OPERATION_NOT_FOUND，不能把“没找到”解释为“设备肯定没有执行”。

重启发现执行中的操作，应按硬件可验证事实恢复查询或结束为 failed/unknown 并使配置失效；没有证据时不要重新执行整段写入。用户手动确认未知结果并结束前端跟踪之后，仍需重新读取可信基线才能再次保存。

## 7. Rust 实现边界与序列化

以下是建议模块划分，不是要求重命名现有 Rust 代码：

| 模块 | 职责 |
|---|---|
| `ipc/discovery` | 监听地址、私有 token 文件、原子更新 |
| `ipc/session` | WebSocket、认证状态、JSON-RPC 分发、每连接发送队列 |
| `ipc/wire` | 与 Schema 一致的传输 DTO 和稳定错误码 |
| `runtime/state` | 状态快照、单调序号、订阅注册、广播 |
| `runtime/configuration` | 可信基线、baseToken、范围检查与配置修订 |
| `runtime/operations` | 幂等索引、持久化、查询、每设备执行调度 |
| `device/*` | BLE 与固件协议、ACK、超时、设备状态证据 |

IPC DTO 不直接复用 BLE struct 或数据库记录。Rust snake_case 字段出站必须转为文档中的 camelCase；action/macro step 使用 `type` 内部标签。用 Serde 实现时，为枚举变体及其字段显式配置线上名称，尤其是 keyDown/keyUp/releaseAll/noOp/keyCode/delayMs，不能假设 Rust 名称自然匹配。

sequence 在线上 DTO 使用字符串，内部按 u64 校验；baseToken/operationId/deviceId 始终视为不透明字符串。optional 字段允许 null 或省略，必需数组不能返回 null。业务校验在 DTO 解析之后执行，包括角色/状态唯一性、scope 一致性和设备限制。

不要将本地文件路径、固件 Flash 地址、RGB565 数据、BLE 包编号或 UI 本地化文本放入配置接口。当前选中的 GIF 只保存在 Studio 本地，没有上传给 Rust。

## 8. 联调步骤

### 8.1 先运行现有 fixture，确认前端环境

在 Studio 仓库根目录运行：

```sh
python3 scripts/mock-runtime-server.py
```

stdout 给出临时 discovery 文件的路径。Xcode 选择 **Studio Frontend**，Edit Scheme → Run → Arguments → Environment Variables，添加：

```text
AHAKEY_RUNTIME_DISCOVERY = 上一步输出的绝对路径
```

运行后验证设备状态、修改亮度、保存、操作 completed。这个 Python 服务是协议 fixture，不含真实 BLE、生产持久化或完整多客户端广播。

### 8.2 换成 Rust 服务

1. 退出旧版 AhaKey Studio/旧设备后台，确保目标设备只有 Rust 管理。
2. 启动 Rust，使它写出本节前面约定的 discovery 文件。
3. 将 Xcode 的环境变量改为 Rust 文件路径；若采用默认路径，删除测试覆盖变量。
4. 使用 **Studio Frontend** scheme；不要使用 **Studio Frontend Mock**，后者绕过 WebSocket。
5. 确认 hello → subscribe → configuration.get 成功，设备 ready、基线可信后执行一次保存。
6. 检查 Rust 操作日志与设备实际结果，确认 completed 后重新 get 得到新 baseToken。
7. 在保存中断开 WebSocket，再连接，验证 operation.get 恢复原操作且没有重复 BLE 写入。

也可在构建后直接从 shell 启动真实前端，使进程继承环境变量：

```sh
AHAKEY_RUNTIME_DISCOVERY="/absolute/path/to/discovery.json" \
  "DerivedData/Frontend/Build/Products/Debug/Studio Frontend.app/Contents/MacOS/Studio Frontend"
```

### 8.3 自动验证与验收

现有前端测试命令，在 Studio 仓库根目录运行：

```sh
xcodebuild -project "AhaKey Studio.xcodeproj" -scheme "Studio Frontend" \
  -configuration Debug -destination "platform=macOS,arch=arm64" \
  -derivedDataPath DerivedData/Frontend \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual test
```

Intel Mac 使用 arch=x86_64。现有 WebSocket 测试会自行启动 Python fixture，**不会自动改测正在运行的 Rust 服务**；Rust 接入需要另建对应集成测试或按以下表格验收。

| 验证项 | 必须观察到的结果 |
|---|---|
| 错 token / 未 hello 调业务方法 | 拒绝，不泄漏状态 |
| 已有四份固定 fixtures | Rust 能解析，序列化后结构/字段语义一致 |
| 超过 JS 安全整数的 sequence | `9007199254740993` 原样保留，不发生浮点舍入 |
| 快照交接期间设备变化 | 无事件缺口，客户端最终投影正确 |
| 单模式保存 | 更新指定模式及全局亮度，其他模式保持原值 |
| 同 ID 同请求重复调用 | 返回原受理信息，只执行一次设备写入 |
| 同 ID 不同请求 | OPERATION_ID_CONFLICT，不覆盖原操作 |
| 外部修改后用旧 token 保存 | BASE_CONFLICT，设备没有额外写入 |
| 保存中断线 / accepted 响应丢失 | 原 operationId 可查询，客户端不自动重发 |
| 中途 BLE 失败 | failed + partial/unknown，旧基线失效 |
| Runtime 执行中重启 | 新 instanceId，操作可恢复或诚实报告未知，不盲目重写 |
| 两个客户端订阅 | 两端收到对应订阅的变化事件 |
| 全新且不可回读的设备 | configuration=null；通过明确初始化流程后才允许保存 |

[schema.json](../contracts/runtime-v1/schema.json) 当前只提供 `$defs`，没有根 `$ref`。校验 fixture 时必须选择对应定义；仅拿整份 Schema 当根校验会失去约束。映射为 hello.json → Hello、subscription.json → Subscription、configuration.json → ConfigurationDocument、apply.json → Apply。另须用 Rust 业务测试覆盖唯一性、完整写入组、幂等与并发语义。

## 9. 当前前端限制与排错

| 现象 | 优先检查 |
|---|---|
| 一直离线 | discovery 路径、owner/0600、loopback IP、服务已监听、token、major=1、methods 含 runtime.subscribe |
| 约 10 秒后断开 | RPC 是否被 BLE 长任务阻塞；apply 是否及时 accepted；id 是否原样返回 |
| 设备显示但不能保存 | 是否 ready、configuration 是否非 null、是否有未决操作/外部变更/草稿校验错误、是否声明 apply |
| 事件没有生效 | method 是否 runtime.event，instanceId/subscriptionId 是否匹配，sequence 是否字符串且递增，data 是否完整 |
| 保存后仍提示基线失效 | 完成前先提交新基线；优先先发 configuration.changed，再发 completed，避免完成触发的 get 随即被旧顺序事件作废 |
| 显示结果未知 | operation.get 找不到原 ID；检查持久化、重启恢复与记录保留策略 |

现有前端仅在建立 Runtime 会话及自身操作 completed 后自动尝试读取基线。若启动时设备列表为空、设备后来才出现/ready，或收到外部 configuration.changed，用户可能需要点击“重新读取基线”；当前没有这些场景的全自动基线刷新。不能靠伪造 ready 或默认配置绕过此限制。

当前不支持 OLED/GIF 上传、物理灯效预览、Hook 管理、语音 host、文本注入、固件刷写、多设备选择、切换设备工作模式和字段级未知配置写入。切换 Studio 编辑模式标签只改变草稿编辑范围，不会调用设备切换模式。上述能力需要同步增加前端接口、Rust 实现和 fixtures，不能仅在 methods 中声明名字就获得 UI 支持。

## 10. 相关代码

- [当前协议摘要](../contracts/runtime-v1/README.md) 与 [JSON Schema](../contracts/runtime-v1/schema.json)
- [Swift 线上 DTO](../StudioFrontend/Runtime/RuntimeDTOs.swift) 与 [WebSocket 客户端](../StudioFrontend/Runtime/IPCRuntimeClient.swift)
- [订阅和事件投影](../StudioFrontend/State/RuntimeStore.swift) 与 [保存及恢复逻辑](../StudioFrontend/State/StudioModel.swift)
- [草稿到线上配置转换](../StudioFrontend/State/StudioDraftStore.swift)
- [可运行的 Python WebSocket fixture](../scripts/mock-runtime-server.py) 与 [前端测试](../Tests/StudioFrontendTests/RuntimeTests.swift)
- [旧设备协议](ble-protocol.md) 与 [旧版固件编码](../AhaKey%20Studio/Services/Bluetooth/LegacyDraftEncoding.swift)，仅用于设备适配参考
