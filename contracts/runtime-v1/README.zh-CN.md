# Studio 前端第一阶段协议

[English](README.md) · **简体中文** · [日本語](README.ja.md)

> 分支范围：本文描述 [`dev`](https://github.com/AhakeyAI/AhaKey-Studio-mac/tree/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c) 上的 Studio/Rust 实现。本次 `main` 只接收文档；前端命令需在该实现的检出目录运行，相关源码、fixtures 和构建目标不包含在此文档分支中。

这是 `StudioFrontend/Runtime` 已消费、通过 Mock 和独立 WebSocket fixture 验证的接口子集。Rust Runtime 尚未实现该接口，不能把本目录当作真机兼容性证明。之前 `docs/runtime-studio-*.md` 中的完整功能规划仍属后续设计；本目录明确当前前端实际发送和读取的字段。

`schema.json` 定义传输数据，`fixtures/` 给出固定 JSON 样例。Rust 接入时应使用相同 fixtures 做反序列化测试；不能直接使用语言默认的枚举序列化。`Apply.changes.modes[].lights` 在本阶段是 `{state,effect}` 数组；后端团队确定扩展模型时需一起更新协议版本、两端 DTO 和 fixtures。

Rust 实现与联调步骤见 [Rust 后端开发文档](../../docs/zh/rust-backend-integration.md)。

## 连接

客户端读取当前用户私有的 discovery 文件：

```json
{"endpoint":"ws://127.0.0.1:12345/","token":"example-only"}
```

默认位置为 `~/Library/Application Support/AhaKey/runtime/discovery.json`，可用 `AHAKEY_RUNTIME_DISCOVERY` 指定其他文件。文件必须为当前用户拥有的普通文件，权限不得向其他用户开放（推荐 0600），大小小于 16 KiB。只接受 loopback IP 的 `ws` 地址，拒绝 URL 中的认证信息、query、fragment 和 HTTP 重定向。真实服务端还需校验认证、Origin 和客户端权限。

一个 WebSocket 文本消息为一个 JSON-RPC 2.0 对象。请求 id 是字符串；文本消息上限 1 MiB，最多 32 个在途请求，请求超时 10 秒。前端有一个接收循环和串行发送出口，按 id 配对乱序响应。

第一条请求为 `runtime.hello`：

```json
{"jsonrpc":"2.0","id":"hello-1","method":"runtime.hello","params":{"protocol":{"major":1,"minor":0},"client":{"name":"AhaKey Studio","version":"0.1.0","kind":"studio"},"token":"example-only"}}
```

结果形状见 `fixtures/hello.json`。major 必须为 1。`methods` 只声明当前真正支持的方法。

## 方法与事件

| 方法 | params | result |
|---|---|---|
| `runtime.subscribe` | `{"topics":["state"],"cursor":null}` | `Subscription` |
| `configuration.get` | `{"deviceId":"..."}` | `ConfigurationDocument` |
| `configuration.apply` | `Apply` | `{"operationId":"...","status":"accepted"}` |
| `operation.get` | `{"operationId":"..."}` | `Operation` |
| `device.connect` / `device.disconnect` | `{"deviceId":"..."}` | JSON 结果，前端忽略具体字段，等待状态事件 |

后端负责发现设备并将可选择连接的设备放入快照；首版 UI 使用快照中的第一台设备。尚未实现主动扫描与多设备选择界面。Rust 接入可先返回一个已知 X1 的状态。

订阅必须先原子注册并取得快照，发送响应后再发比快照更新的事件：

```json
{"jsonrpc":"2.0","method":"runtime.event","params":{"subscriptionId":"...","instanceId":"...","sequence":"9007199254740994","type":"device.changed","data":{"deviceId":"x1","name":"AhaKey","connectionState":"ready","batteryPercent":null,"workMode":0,"lever":"manual"}}}
```

- `device.changed` 携带完整 `Device` 投影，连接状态 ready 才允许保存；拨杆字符串为 automatic/manual，未知值按未知展示。
- `operation.changed` 携带完整 `Operation`。status 为 accepted/running/completed/failed/cancelled，effect 可为 none/partial/unknown/complete。
- `configuration.changed` / `configuration.invalidated` 至少携带 deviceId，用于阻止继续用旧基线保存。
- `sequence` 是 UInt64 十进制字符串；大于 JavaScript 安全整数范围的序号有测试覆盖。过滤后的全局序号允许有间隙。
- 前端缓冲订阅响应交接期间的事件，忽略旧订阅/旧实例/旧序号。重连总是重新取快照，不依赖事件重放。

## 配置和操作

当前保存包含指定模式的完整四个键位、九种 IDE 状态灯效和设备级亮度。scope 必须与 changes 一致，重复 mode、role、state 应由后端拒绝。键位 action 是 shortcut/macro/disabled；modifier 使用 control/shift/alt/gui；keyCode 使用 HID usage，宏 delayMs 使用毫秒。当前 X1 限制仍需后端权威校验：描述 ASCII 20 字节、宏最多 49 步、延迟为 3ms 的倍数且不超过 765ms。前端预校验不替代后端验证。

`configuration.get` 无法确认完整配置时返回 `configuration:null`。前端将保留草稿并禁用保存，不用默认值冒充设备事实。本阶段没有部分未知字段的写入能力；后续需扩展字段证据模型。

operationId 在发送前保存到本地；同 ID、相同内容必须去重，不同内容返回 OPERATION_ID_CONFLICT。受理响应丢失不自动重发写请求，重连后以相同 ID 查询。OPERATION_NOT_FOUND 表示结果未知；用户核对设备并结束跟踪后，仍需重新读基线才可再次保存。

completed 表示后端定义的全部配置确认条件已满足。前端不自己计算 ACK、不把 accepted 当成功。部分失败必须返回 effect=partial/unknown，不能宣称回滚。后端需要明确操作记录留存与重启后的未知结果语义。

错误采用 JSON-RPC error，稳定业务码放在 `error.data.code`，例如 BASE_CONFLICT、DEVICE_NOT_READY、DEVICE_TIMEOUT、BUSY、INCOMPLETE_WRITE_GROUP、OPERATION_NOT_FOUND。前端不展示任意服务端 error.message；标准 -32602/-32601 分别映射为 INVALID_PARAMS/UNSUPPORTED_CAPABILITY。

资源上传、设备预览、Hook、语音 host、刷机及完整权限模型不属于当前接口子集。选中的 GIF 只保存在 Studio 草稿，不随 configuration.apply 发送。设备层的 Flash 地址、RGB565、包大小和固件编码不出现在本接口。

## 本地联调

运行 `python3 scripts/mock-runtime-server.py`，stdout 会给出临时 discovery 文件路径。把该路径设为 Xcode 的 `AHAKEY_RUNTIME_DISCOVERY` 环境变量，再运行 `Studio Frontend` scheme。该服务器是单客户端联调 fixture，不实现多客户端广播、生产存储、硬件校验或资源上传，不应分发为真正 Runtime。

`StudioFrontendTests.testRealWebSocketClientAgainstPythonFixture` 自动启动此服务器，验证真实 URLSession WebSocket 握手、认证、配置查询/提交、事件及操作查询；测试结束时关闭服务器。
