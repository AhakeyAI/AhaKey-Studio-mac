# AhaKey Runtime ↔ Studio / SDK 协议设计 v1

状态：设计提案，尚未实现或经过硬件验证。日期：2026-09-08。

基线修正：用户随后明确以 desktop 的 main 为迁移目标。本文原基线是 upstream/runtime，不能直接声称覆盖 main。main 的全局亮度、设备按键描述、单动画/70 帧布局、命令确认限制与补充接口，见 [main Swift 设备交互审阅](runtime-device-interaction-main.md)；对 main 的实现以该文的差异约束为准。

依据：`AhakeyAI-desktop` 仓库 `upstream/runtime`，固定提交 `13240bb8d1ff92061eddf0a9b7d70c77d29e8b8d`。目标是保留该分支已有的交互语义，供 Rust 或 Go Runtime 和 Swift / 其他语言客户端共同实现。

## 1. 决策与职责

控制消息使用 UTF-8 JSON，信封采用 [JSON-RPC 2.0](https://www.jsonrpc.org/specification)。图片使用独立二进制消息，配置中只引用资源 ID。v1 建议使用本机 WebSocket 长连接，一个客户端一条连接，允许同时存在 Studio 和多个 SDK。

JSON-RPC 只定义请求、响应和通知；下面的握手、订阅、操作和上传规则是 AhaKey 自己的协议。

Studio 负责编辑草稿、预览、显示状态、提交用户操作。Runtime 独占硬件连接，负责能力协商、配置差异计算、固件适配、RGB565 编码、分包、ACK、排队、持久化与恢复。图片裁剪等编辑结果可以由 Studio 生成，Runtime 必须能够接收规范化 GIF，SDK 不必实现固件编码。

这是对现有分工的调整：现有 Studio assembler 生成部分计划/指纹；新版本把权威计划生成集中在 Runtime。不能只替换 Codable 编码器就视为完成迁移。

Studio 退出不停止 Runtime，也不取消已受理的配置操作。SDK 使用完全相同的接口。IPC 连通和键盘连通是两个状态。

## 2. 连接与消息边界

- WebSocket 只监听 loopback，地址由用户私有的 discovery 文件提供；端口不写死在 SDK。文件包含 endpoint 和随机 token，Unix 文件权限仅当前用户，Windows 使用当前用户 ACL。
- 首条请求必须是 `runtime.hello`，验证 token 后才能查询或修改。检查浏览器 Origin，v1 不开放任意网页来源；token 不放 URL 或日志。客户端自报 `kind` 只作标识，不作为授权依据。
- 一条 WebSocket **文本消息**对应一个完整 JSON 对象；使用库重组消息，不能把网络 read 或 WebSocket fragment 当成完整 JSON。
- 一条二进制消息对应一块资源。业务不会按 BLE 包大小发 IPC 请求。
- v1 客户端使用单请求对象，不发送 JSON-RPC batch。响应允许乱序，必须按 `id` 配对；所有修改请求必须有 `id`。
- 每个连接只有一个串行发送出口、一个接收分发循环。发送不会重新 connect。
- 如果以后改用 UDS / Named Pipe，可以保留业务模型；字节流必须另外定义长度帧，不能直接把本文件的 WebSocket 消息边界假设搬过去。v1 无需同时实现多个传输。

## 3. 三种 JSON 消息

请求：`id` 是客户端生成的非空字符串，当前连接的未完成请求之间唯一。

```json
{"jsonrpc":"2.0","id":"r1","method":"runtime.snapshot","params":{}}
```

响应使用相同 `id`，`result` 和 `error` 二选一。

```json
{"jsonrpc":"2.0","id":"r1","result":{"instanceId":"rt-example","lifecycle":"running"}}
```

以上 result 仅展示信封；完整快照字段见第 5 节。

事件没有 `id`，无需客户端回复。

```json
{"jsonrpc":"2.0","method":"runtime.event","params":{"subscriptionId":"sub-example","instanceId":"rt-example","sequence":"103","type":"device.changed","data":{"deviceId":"device-example","connection":{"state":"disconnected","transport":"none"}}}}
```

以上 data 为展示节选；实际 `device.changed` 携带完整 DeviceSnapshot，用整体替换，避免漏合并/null 清除歧义。

公共约定：

| 内容 | 编码规则 |
|---|---|
| 字段名称 | camelCase；方法名称为 `domain.action` |
| deviceId / operationId / uploadId | 不透明字符串；后两者使用标准 UUID 字符串 |
| 版本序号、事件序号、累计字节数 | 十进制字符串，避免 JavaScript UInt64 精度丢失 |
| 槽位、帧数、百分比、毫秒 | 有界 JSON 整数；不接受小数、NaN、Infinity |
| 时间 | UTC RFC 3339 字符串；持续时间明确使用 `...Ms` |
| 枚举 | 稳定字符串，不使用 Swift/Rust 自动生成的枚举 JSON 形状 |
| 未知状态 | `null`，不使用 0、空字符串或 -1 冒充已知状态 |
| 响应新增字段 | 旧客户端忽略；未知枚举保留原值，UI 显示未知 |
| 修改请求的未知字段 | 返回 invalid params，不能忽略用户期望写入的内容 |

`deviceId` 由 Runtime 管理并持久化，不要求客户端使用 BLE 地址或 CoreBluetooth UUID。多个传输只有在身份匹配有依据时合并，不能按设备名称合并；未确认身份的发现记录只使用临时 discoveryId。

## 4. 握手

```json
{
  "jsonrpc":"2.0","id":"hello-1","method":"runtime.hello",
  "params":{
    "protocol":{"major":1,"minor":0},
    "client":{"name":"AhaKey Studio","version":"0.1.0","kind":"studio"},
    "token":"example-only"
  }
}
```

返回 `protocol`（协商版本）、`runtimeVersion`、`instanceId`（每次 Runtime 启动变化）、`methods`（实际可调用的方法名数组）、`configurationSchemas`、`limits`。相同 major 协商双方支持的 minor；major 不兼容返回 `PROTOCOL_MISMATCH`。这些版本独立于固件版本、应用版本和旧 XPC interfaceVersion。

建议初始 limits：`maxJsonMessageBytes=1048576`、`maxUploadChunkBytes=65536`、`maxInFlightRequests=32`。资源大小、解码内存、上传数量和操作队列也必须有实际生效的上限并在握手返回；数值以当前资源策略/测试结果确定，不能声称这些建议已经过测量。超过并发额度返回 BUSY，不无限增加任务。

Runtime 的 `methods` 与每个设备的 capabilities 分别表达“程序实现了什么”和“这个设备现在能做什么”。只有声明而未实现的方法不得广告为可用。

## 5. 状态、页面和事件

`runtime.snapshot` 返回同一个一致性时点的：

| 字段 | 内容 |
|---|---|
| instanceId / sequence | 进程实例与该快照覆盖到的事件位置 |
| lifecycle | starting / running / stopping / unavailable |
| devices / activeDeviceId | 完整设备列表与 UI 默认选择；写请求仍须显式指定 deviceId |
| operations | 所有未结束操作和有界数量的最近结束操作 |
| policy / policyRevision | AhaType、AI Hook、路由、显示、节电、诊断设置 |
| permissions | 各权限状态及所属进程/功能，例如 Studio 的 microphone，Runtime 的 bluetooth |
| keepAliveReasons | 当前后台工作原因，如 aiHooks、activeOperation |

DeviceSnapshot 固定包含：

```json
{
  "deviceId":"device-example",
  "name":"AhaKey",
  "connection":{"state":"ready","transport":"bluetooth","sessionId":"session-example"},
  "transports":{"bluetooth":{"connected":true},"usb":{"attached":false,"usable":false}},
  "capabilities":{
    "writablePages":["key","lights","screen"],
    "oled":{"profile":"currentSessionCapable","width":160,"height":80,"setCount":2,"maxFramesPerAsset":30,"sessionUpload":true}
  },
  "state":{"batteryPercent":82,"workMode":0,"lightMode":1,"leverPosition":"up","brightnessPercent":60,"firmwareVersion":"example","activeTaskSets":[{"mode":0,"set":0}]},
  "observedAt":"2026-09-08T12:00:00Z"
}
```

这是示例能力，不是所有固件的固定限制。`connection.state` 为 disconnected / connecting / probing / ready / restricted / failed；协议协商完成前不能用 connected 表示可写。旧 `legacyDenied` 映射为 restricted，并附 reasonCode。断线后可保留上次 state/observedAt，但必须以 disconnected 展示为缓存。

OLED profile 保留 legacyStandard / rhinoDualSet / currentSessionCapable / unsupported，并独立返回 sessionUpload 及实际布局。连接代次和固件能力变化由 Runtime 处理，不根据版本字符串猜可写性。UI 可从 writablePages 和字段限制决定显示哪些控件。

`configuration.getPage({deviceId,page})` 返回 `page`、`baseToken`、`fields`、字段约束、`writeGroups`。每个 field 的形状为 `{field,value,trust,provenance}`。trust 是 verified / writeConfirmed / unknown；provenance 是 deviceReadback / writeConfirmation / absent，纯展示元数据另用 runtimeStored。按键 description 等 Runtime 元数据不能伪装为设备读回。

baseToken 由 Runtime 生成，客户端原样带回；它代表该页的基线、关联的共享资源布局和能力上下文。不要让各语言客户端计算固件指纹或依赖本地草稿恢复“设备事实”。Runtime 内部仍保留现有 generation、writer lease、指纹和写入确认约束。

`runtime.subscribe({topics:["state"],cursor:null})` **原子地注册订阅并取得快照**，返回 `{subscriptionId,snapshot}`，先发送该响应，再发送 sequence 大于快照 sequence 的事件。这样不存在“读完快照、尚未订阅”丢事件的窗口。

重连可传 `cursor:{instanceId,sequence}`。同实例且缓存覆盖时，返回 replay 模式及 replayThrough，响应后依序重放直到该位置再进入实时流；实例变化或缓存不足时直接返回 snapshot 模式及完整新快照。新 subscriptionId 使客户端能够丢弃旧连接残留回调。客户端通过 replayThrough 确定何时追平。

topics 分为 state 和 diagnostics，序号是 Runtime 全局递增序号；过滤 topic 会产生正常空隙，不能据此误报丢包。状态事件包括 device.changed/device.removed、operation.changed、policy.changed、permissions.changed、lifecycle.changed、keepAliveReasons.changed 和 state.invalidated。除 removed/invalidation 外携带该实体完整的新投影。失效事件要求重新建立快照订阅。

慢客户端的发送缓冲达到上限时关闭该连接，由快照恢复，不能拖住设备控制。进度先合并再编号发布；操作终态和落盘事实不能因事件缓冲丢弃而丢失。`runtime.unsubscribe` 用 subscriptionId 停止订阅。

## 6. 配置写入格式

只提交当前页的修改。字段集合本身就是 field mask，不发送整份 Studio 草稿。

```json
{
  "jsonrpc":"2.0","id":"apply-1","method":"configuration.apply",
  "params":{
    "operationId":"c945f786-7a93-438f-bf33-ce338eeb6670",
    "deviceId":"device-example",
    "page":{"kind":"lights","mode":0},
    "baseToken":"base-example",
    "changes":[{"field":"brightness","value":60}],
    "overwriteUnknown":false
  }
}
```

成功受理返回：

```json
{"jsonrpc":"2.0","id":"apply-1","result":{"operationId":"c945f786-7a93-438f-bf33-ce338eeb6670","status":"accepted"}}
```

- accepted 表示请求和资源引用已持久化，并进入 Runtime 队列，不能显示“键盘写入完成”。
- operationId 由客户端生成，在第一次发送前保存。同一 ID 和同一语义请求返回同一操作；同一 ID 换内容返回 OPERATION_ID_CONFLICT。请求 `id` 可变化。
- Runtime 根据解码后的类型化字段生成语义摘要，不依赖 JSON 键序或某语言的默认序列化。先查已有 operationId，再验证新请求的 baseToken，防止已完成请求重发被误判为新冲突。
- 接收和执行前都校验基线。其他客户端改变了相关字段/共享布局时返回 BASE_CONFLICT，或使尚未写入的已受理操作以 failedWithoutWrites 结束。不能静默覆盖。无关字段可由 Runtime 根据依赖判断是否允许执行，客户端不自行猜测。
- 每设备的持久化配置操作 FIFO，同一设备只有一个配置 writer；live state 也经过同一个设备命令调度器，不能穿插破坏图片事务。不同设备可独立工作。
- 缺省字段表示不改；`value:null` 仅用于允许清除的字段，例如 voicePreset / taskAsset。空 changes 返回 `{status:"noOp"}` 且不建操作。未改值也由 Runtime 判断 no-op。
- unknown 基线不能被当作已同步。需要显式覆盖时返回 UNKNOWN_BASELINE，并指出 requiredFields；Studio 提示后提交完整所需字段及 overwriteUnknown=true。该标志不豁免 baseToken 和能力校验。
- 某些旧固件必须整组写图。getPage 的 writeGroups 返回成员；若既未提供完整组，也没有可信未改成员可补齐，则返回 INCOMPLETE_WRITE_GROUP。不能用其他页面的草稿偷偷补齐。

页面和字段：

| page | field | value |
|---|---|---|
| `{kind:"key",mode:0,role:"approve"}` | action | 显式带 type 的 shortcut 或 macro |
| 同上，role 为 voice/approve/reject/submit | description / voicePreset | string / string 或 null |
| `{kind:"lights",mode:0}` | brightness | 1…100，沿用当前配置范围 |
| 同上 | `mapping.<state>` | 灯效稳定字符串；state 为现有 IDEState 数字的十进制形式 |
| `{kind:"screen",mode:0}` | statusLine / framesPerSecond | string / 1…30 |
| 同上 | `taskSets.<set>.<state>` | 资源引用对象或 null；state 为 idle/working/waiting/done |
| 同上 | activeSet | 0/1，受设备能力约束；未知状态在读响应中用 null |
| `{kind:"lever"}` / `{kind:"power"}` | 保留 | 当前执行映射未证明完整，暂不广告为可写 |

mode 在当前模型为 0…3，但实际允许范围以设备能力为准。mapping state 的有效值和 effect 枚举从 getPage 约束中返回，不能允许任意字符串进入设备编码。

快捷键示例：`{"type":"shortcut","modifiers":["control","shift"],"keyCode":4}`。keyCode 使用现有键盘 HID usage（0 表示仅修饰键），修饰键使用 control/shift/alt/gui；macOS UI 把 option/command 映射为 alt/gui。现有策略中的 function 不能假装成跨平台 HID modifier，仅在支持它的主机快捷键策略中出现。

宏示例：`{"type":"macro","steps":[{"type":"keyDown","keyCode":4},{"type":"delay","durationMs":30},{"type":"keyUp","keyCode":4},{"type":"releaseAll"}]}`。另支持 noOp。适配现有 0…4 的宏 action；delay 须为 3ms 整数倍且可装入旧参数范围，否则返回 FIELD_OUT_OF_RANGE，不静默截断。这配置的是宏，绝不在 apply 时执行宏。

任务图示例：`{"resourceId":"sha256:example","framesPerSecond":10}`。resourceId 的实际摘要必须是 64 位小写十六进制；资源元数据由上传完成响应返回。顶层旧 defaultAnimation 与 A 套 done 图的镜像关系由 Runtime 适配，避免暴露两个可相互矛盾的写字段。

## 7. 图片资源：一次上传、多处引用

1. 调用 `resource.begin({sha256,byteCount,mediaType:"image/gif"})`。Runtime 已有相同完整内容则返回 `{status:"exists",resourceId,metadata}`；否则返回 `{status:"upload",uploadId,chunkBytes}`。
2. 发送二进制消息，每块最多协商的 chunkBytes。v1 同一 upload 一块在途，等待 ack 后发下一块，避免整张图多次复制进消息队列。
3. 调用 `resource.finish({uploadId})`。Runtime 核对长度、SHA-256 和实际解码尺寸/帧数，存入持久资源存储，然后返回 `{resourceId,metadata:{width,height,frameCount,byteCount,mediaType}}`。
4. configuration.apply 只引用 resourceId。已存在资源也要复核与目标设备约束相容。

二进制消息布局固定为：

```text
0..3    ASCII "AHAB"
4..19   uploadId 的 UUID 原始 16 字节（UUID 字符串去掉横线后按十六进制顺序解码）
20..27  offset，uint64，大端字节序
28..    原始资源字节
```

Runtime 使用 JSON 通知 `resource.ack` 返回 `{uploadId,nextOffset:"65536"}`；错误使用 `resource.rejected` 返回 `{uploadId,code}` 并停止该上传。ack 表示块已接收到临时文件，不等于资源已持久化成功。offset 必须等于当前 nextOffset，不做乱序重排。

断开 IPC 后，v1 丢弃该连接未完成的 upload，重连重新 begin；已 finish 的资源不重传。上传句柄归创建连接所有；finish 重复调用在原连接内返回同一结果。客户端断线不清理被已受理操作引用的资源。

Runtime 流式落临时文件并计算摘要；限制源文件体积、解码后的总像素/帧数和并行编码数量。上传进度和向键盘写入进度是两个不同阶段，不混成一个百分比。

资源 v1 保证接收 Studio 现有流程的规范化 160×80 GIF。原始大图/任意视频解码不是迁移前提，可以以后作为独立能力；SDK 可生成规范化 GIF。当前 30 帧上限来自每素材策略，不等于固件 userSlotLimit。GIF 到 RGB565、物理槽位分配、session prepare/abort 等全部留在 Runtime。

未引用资源设置有界缓存和过期策略；新上传结果返回 expiresAt，apply 在同一事务中校验存在并固定引用。被未结束操作及有效已确认配置引用的资源不按临时 TTL 删除。过期返回 RESOURCE_MISSING，客户端重新上传。

## 8. 操作状态与部分成功

`operation.get({operationId})` 和 operation.changed 采用同一 OperationSnapshot。最少包含 operationId、deviceId、page、status、phase、progress、result、error、recovery、queueOrder、updatedAt；不适用字段为 null。

```json
{
  "operationId":"c945f786-7a93-438f-bf33-ce338eeb6670",
  "deviceId":"device-example",
  "page":{"kind":"screen","mode":0},
  "status":"running",
  "phase":"transferring",
  "progress":{"completedSteps":2,"totalSteps":5,"sentBytes":"384000","totalBytes":"768000","confirmedBytes":"0"},
  "result":null,
  "error":null,
  "recovery":{"canResume":false,"canCancel":true,"canAbandon":false,"abandonEligibleAt":null},
  "queueOrder":"17",
  "updatedAt":"2026-09-08T12:00:01Z"
}
```

示例 ID 仅展示结构，独立于第 6 节的灯光操作。sentBytes 指本次计划的有效载荷已交给传输层的数量，不含重试重复字节，不作为写入证明；confirmedBytes 只有对应设备确认后才增长，不支持逐块确认的固件可直到整图 ACK 后跳变。phase 为 queued / preparing / transferring / confirming / waitingForDevice / finished。

状态保留现有含义，另明确取消结果：

| status | 含义 |
|---|---|
| accepted / running | 已持久化待执行 / 执行中 |
| paused / resumablePartial | 等待设备或条件 / 有部分确认结果，可恢复 |
| cancellationRequested | 正在寻找安全取消位置 |
| completed | 本次所请求字段全部达到各自确认条件 |
| cancelled | 已安全停止且没有确认写入；不表示设备全局回滚 |
| failedWithoutWrites | 失败且能够确认没有设备写入 |
| failedWithPartialCommit | 终止，有已确认写入或无法排除写入影响 |

result 返回 `confirmedFields`（字段与新 baseline）、`remainingFields`、`uncertainFields` 和 `stopReason`。元数据写入以 Runtime 持久化确认；硬件字段必须有现有固件协议允许的 ACK/读回证据，不能因 socket write 返回成功就确认。能力不足以读回时 trust 只能是 writeConfirmed。

`operation.cancel` 返回 requested / refused / alreadyFinished / notFound。取消 IPC 等待、取消已受理操作、回滚硬件是三件事；v1 不承诺设备事务回滚。

`operation.resume` 是新接口，只有 canResume=true 才能调用；恢复前由 Runtime 重核设备身份、能力和基线。已有自动恢复由 Runtime 继续承担。不能简单从“最后发出的 BLE 字节”继续，应从最后可靠确认的事务步骤恢复；不确定步骤按固件能力重试或标记 uncertain。

`operation.abandon` 保留现有规则：仅 FIFO 队首 paused/resumablePartial 操作，且设备实际持续断连满 60 秒后可放弃。由 Runtime 返回 canAbandon/abandonEligibleAt，Studio 不用自己的 IPC 断线时间计算。返回 abandoned / refused / alreadyFinished / notFound；放弃后部分事实仍保留，并解除其队列阻塞。

Runtime 重启后从持久记录重建操作和已确认字段。终态/去重记录按有界留存策略保存，握手公开 retention；保证仅在留存窗口内成立，不宣称设备恰好执行一次。找不到旧操作时客户端显示结果未知，不能自动换新 ID 重发可能有副作用的请求。

## 9. 方法覆盖与现有实现差异

| 新方法 | 目的 | 当前分支依据 |
|---|---|---|
| runtime.hello / snapshot | 握手、完整状态 | XPC handshake / snapshot |
| runtime.subscribe / unsubscribe | 推送、重连补状态 | events(after:) 的 replay / snapshotRequired；现在是 long-poll |
| configuration.getPage / apply | 可信基线、页面局部写入 | pageBaselines、pageScope、fieldMask、apply(package) |
| resource.begin / finish | 资源上传与复用 | ingestResources、摘要验证、CAS；分块帧是新设计 |
| operation.get / list | 查询、重开 Studio 恢复进度 | snapshot.operations / 持久事务记录 |
| operation.cancel / abandon | 取消、放弃部分操作 | requestCancellation / requestAbandon |
| operation.resume | 主动请求恢复 | 新接口，复用已有 Runtime 恢复能力 |
| diagnostics.list | 查询日志事件 | diagnostics(after:)；返回有界事件和 nextCursor |
| policy.get / update | Runtime 功能设置 | policy 模型已有，**当前 Agent XPC switch 未处理 updatePolicy** |
| device.getState | cached / refresh 状态 | snapshot 与 legacy status / approval_status 的主动拨杆查询 |
| device.setPresentation | 临时 IDE 状态及延时重置 | legacy state / state_with_reset |
| device.setLeverOverride | 虚拟拨杆设置/清除 | legacy set_switch_override |
| integration.publishState | Hook 状态输入 | typed aiState |
| integration.getApproval | 获取当前批准模式判断 | typed approvalQuery；不执行外部批准动作 |
| integration.reportPermission | 发布等待状态并读取拨杆 | legacy permission 的组合语义 |
| firmware.startUpgrade | 保留名称，v1 不广告 | 当前仅声明请求，Agent 未处理 |

operation.list 使用 `{deviceId,statuses,limit,cursor}` 分页返回 `{operations,nextCursor}`，limit 有协商上限。policy.get 返回 `{revision,policy}`；policy.update 使用 `{baseRevision,changes}`，成功返回新 revision/policy，冲突报 BASE_CONFLICT；这是需要补齐的实现，不能映射到一个假成功响应。

policy 保留 ahaType.enabled/trigger、aiHooks.enabledTools/approvalPolicy、voiceRouting、devicePresentation.ledEnabled/oledEnabled、powerProtectionEnabled 和 diagnostics.verboseProtocolLoggingUntil。按平台广告支持的字段；麦克风授权/系统设置页面等主机 UI 行为由对应前端处理，协议只报告状态。

device.getState 使用 `{deviceId,freshness:"cached"|"refresh"}`，返回 `{state,observedAt,source:"device"|"cache",stale}`。refresh 超时返回 DEVICE_TIMEOUT，不以缓存冒充本次硬件读取；缓存仍能单独查询。

device.setPresentation 使用 `{deviceId,stateCode,reset:null|{stateCode,afterMs}}`，stateCode 保留当前 UInt8 状态编码且限定在设备支持集合，返回 queued。它是瞬时状态，不写配置闪存；新状态取代旧延时重置任务。Runtime 接收顺序决定当前值，已有 Hook 聚合/会话路由仍在 Runtime，普通 SDK 不绕过调度器。

device.setLeverOverride 使用 `{deviceId,position:"up"|"middle"|"down"|null}`，返回 physical/effective/override 三个值，真实设备上报清除临时 override，沿用现有行为。

integration.publishState 使用 `{source:"claude"|"codex"|"cursor"|"kimi",event:"idle"|"working"|"permissionRequested"|"awaitingFollowup"|"sessionEnded",eventId,sessionId}`；后两个为客户端生成字符串。eventId 用于短期重复去重，sessionId 用于隔离并发会话，均不等于设备连接 sessionId。sessionId 是在现有 Hook 基础上的显式扩展，客户端身份仍需验证。

integration.getApproval 使用 `{deviceId,sessionId,freshness}`，返回 `{decision:"automatic"|"manual"|"unavailable",leverPosition,source,observedAt}`。integration.reportPermission 使用同样参数加 eventId/stateCode，语义为发布等待状态后执行 refresh 查询。读取失败返回 unavailable，不承诺替任何第三方应用批准请求。

上述临时修改在 Runtime 重启后不自动恢复，响应丢失也不自动重试；需要新状态时由调用者再次明确发送。只有 configuration.apply 使用持久 operationId 去重。

## 10. 错误格式

```json
{
  "jsonrpc":"2.0","id":"apply-1",
  "error":{
    "code":1002,
    "message":"Configuration baseline changed",
    "data":{"code":"BASE_CONFLICT","deviceId":"device-example","page":{"kind":"lights","mode":0},"retryable":false}
  }
}
```

保留 JSON-RPC 的 -32700/-32600/-32601/-32602/-32603 标准错误。应用错误固定映射：1001 DEVICE_NOT_READY，1002 BASE_CONFLICT，1003 UNSUPPORTED_CAPABILITY，1004 RESOURCE_MISSING，1005 OPERATION_ID_CONFLICT，1006 BUSY，1007 DEVICE_TIMEOUT，1008 RESOURCE_INVALID，1009 PERMISSION_DENIED，1010 UNKNOWN_BASELINE，1011 INCOMPLETE_WRITE_GROUP，1012 FIELD_OUT_OF_RANGE，1013 PROTOCOL_MISMATCH，1014 AUTH_REQUIRED，1015 RESOURCE_LIMIT。

message 用于开发诊断；Studio 根据 data.code 本地化。retryable=true 仅表示条件变化后可能重试，不授权 SDK 自动重复修改。受理之前的错误在响应中返回；受理之后的设备错误在 OperationSnapshot.error 中返回 `{code,message,context}`。context 可含 field、step、deviceStatus；opcode 放诊断数据，不要求 UI 理解。

## 11. 最小迁移与验收

先实现 hello → subscribe 快照 → getPage → apply → operation.changed；随后加入分块资源和其余兼容方法。新旧 IPC 过渡期必须共用同一个设备 owner 和事务队列，不允许新 Runtime 与旧 Agent 同时抢键盘。

协议实现完成的条件：

1. 两客户端同时连接，状态一致；冲突页修改被明确拒绝，无无声覆盖。
2. 持久受理后关闭 Studio，写入继续；重开能显示同一操作，不重复提交。
3. 模拟受理响应丢失，使用相同 operationId 重发只产生一个逻辑操作。
4. 图片上传只占有界缓冲；只有 finish 成功才能引用，进度与硬件确认分开。
5. USB/BLE 切换、真实设备断连、Runtime 重启后，状态和基线不会沿用旧连接事实。
6. 覆盖 Standard / Rhino / current 的图片布局和 A/B 套图语义；未支持能力明确禁用。
7. 部分写入后断连、取消、60 秒后放弃，已确认字段仍保留，未确认字段不会显示已同步。
8. 订阅建立时恰逢变化、事件缓存溢出、慢客户端断开，都能通过一致快照恢复。
9. Swift 与第二种语言客户端交换相同 JSON 样例；序号超过 2^53 仍不丢精度；未知字段与 null 按约定处理。

这里只完成设计与当前代码对照，以上属于未来实现的验收用例，不代表已经通过。

## 12. 代码依据索引

以下路径均相对于上述固定提交的 `AhakeyAI-desktop` 仓库，不能用当前工作分支的同名文件代替：

- `ahakeyconfig-mac/Sources/Shared/AhaKeyRuntimeProductionSeam.swift:320`：现有 XPC 请求/响应种类。
- `ahakeyconfig-mac/Sources/Agent/AhaKeyAgent.swift:1110`：实际生产分发，区分已实现与仅声明的请求。
- `ahakeyconfig-mac/Sources/Agent/AhaKeyAgent.swift:1375`：旧 JSON 命令、拨杆实时查询、临时状态。
- `ahakeyconfig-mac/Sources/Shared/AhaKeyDesiredConfiguration.swift:42`：模式、按键、宏、OLED 和灯光模型。
- `ahakeyconfig-mac/Sources/Shared/AhaKeyStudioPageModel.swift:4`：页面与字段归属、基线可信度。
- `ahakeyconfig-mac/Sources/Shared/AhaKeyRuntimeContract.swift:1044`：操作状态、部分结果与放弃规则。
- `ahakeyconfig-mac/Sources/Shared/AhaKeyRuntimeContract.swift:1654`：快照及事件类型。
- `ahakeyconfig-mac/Sources/Shared/AhaKeyRuntimePageOperation.swift:6`：页面范围、指纹和资源绑定约束。
- `ahakeyconfig-mac/Sources/Shared/AhaKeyOLEDCompatibilityProfile.swift`：固件兼容分类和图片能力。
