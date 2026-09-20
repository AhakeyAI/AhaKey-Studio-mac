# Rust Runtime integration guide for Studio

**English** · [简体中文](zh/rust-backend-integration.md) · [日本語](ja/rust-backend-integration.md)

> Branch scope: this guide describes the Studio/Rust implementation on [`dev`](https://github.com/AhakeyAI/AhaKey-Studio-mac/tree/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c). The `main` branch receives documentation only in this change. Run frontend commands from a checkout of that implementation; its source, fixtures, and build targets are not included in this documentation branch.

This guide describes protocol `1.0` used by the **Studio Frontend** target implemented on `dev`. Rust Runtime owns device connections, state, and configuration writes; the SwiftUI frontend calls it over a local WebSocket. The client behavior described here is implemented, but the Rust server and hardware workflow have not yet been verified together.

Use [RuntimeDTOs.swift](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/StudioFrontend/Runtime/RuntimeDTOs.swift), [IPCRuntimeClient.swift](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/StudioFrontend/Runtime/IPCRuntimeClient.swift), and the [protocol fixtures](https://github.com/AhakeyAI/AhaKey-Studio-mac/tree/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/contracts/runtime-v1/fixtures) as the field reference. Earlier `runtime-studio-*.md` documents include broader plans and are not the current client contract.

## 1. What to implement

Implement an independent Rust process running as the current user with these seven methods:

| Method | Purpose | Response timing |
|---|---|---|
| `runtime.hello` | Token authentication, protocol negotiation, capability declaration | Immediately after authentication |
| `runtime.subscribe` | Register a state subscription and return a consistent snapshot | Immediately after registration |
| `configuration.get` | Read a configuration baseline and version token | Read trusted state without waiting for a long device scan |
| `configuration.apply` | Validate and accept a configuration operation | Persist the operation, return `accepted`, then execute device writes asynchronously |
| `operation.get` | Query the original operation and recover a lost result | Read the operation record |
| `device.connect` | Request a connection to a device | Return after enqueueing; publish the outcome through events |
| `device.disconnect` | Request device disconnection | Return after enqueueing; publish state through events |

The first three methods establish connectivity and reads. Saving also requires `configuration.apply`, `operation.get`, and state events. The frontend does not launch Runtime or fall back to the legacy Swift Bluetooth backend. Closing Studio closes its WebSocket; it neither stops Runtime nor cancels accepted operations.

```text
Studio Frontend
  └─ Local WebSocket / JSON-RPC 2.0
       └─ Rust: authentication, subscriptions, baselines, operation records, per-device write queues
            └─ Rust device adapter: BLE, firmware encoding, ACKs, timeouts, state reads
                 └─ AhaKey X1
```

## 2. Startup and discovery configuration

Recommended startup order:

1. Recover configuration and operation records; generate a new `instanceId` on each process start.
2. Listen only on `127.0.0.1` or `::1`, optionally using an OS-assigned free port.
3. Generate an unpredictable session token and atomically publish discovery after the listener is ready.
4. Start device discovery and state maintenance. Snapshots may contain no devices while scanning is incomplete.

Default discovery path:

```text
~/Library/Application Support/AhaKey/runtime/discovery.json
```

Example file; replace the port and token with actual values:

```json
{
  "endpoint": "ws://127.0.0.1:12345/",
  "token": "replace-with-random-runtime-token"
}
```

| Item | Current client requirement |
|---|---|
| File | Regular file owned by the current user, smaller than 16 KiB; no permissions for other users, `0600` recommended |
| Override | `AHAKEY_RUNTIME_DISCOVERY` contains the absolute file path, not a WebSocket URL |
| Address | `ws://127.0.0.1:port/` or `ws://[::1]:port/`; `localhost`, remote addresses, and `wss` are rejected |
| URL | No credentials, query, or fragment; HTTP redirects are rejected |
| Handshake | Standard WebSocket without a requested subprotocol or custom Authorization header |
| Authentication | Token in the JSON params of the first `runtime.hello`, never in the URL |

Use directory permissions `0700`. Create a temporary file in the same directory with `0600`, then rename it to the destination to avoid partial JSON reads. Update the file when restarting with a new port/token; the frontend rereads it on every reconnect. Prevent multiple Runtime processes for the same user from competing for devices or overwriting discovery.

The server must reject business calls before authentication and must not expose snapshots to a wrong token. The native client does not explicitly set Origin. Allow native connections without Origin and reject unauthorized browser Origins; loopback alone is not authentication. Do not log tokens.

## 3. WebSocket and JSON-RPC rules

- Each WebSocket **text message** contains one JSON-RPC 2.0 object. Do not use batch arrays, newline-delimited messages, or binary business messages.
- Request `id` is a string and must be echoed unchanged. RPC `id` and business `operationId` are different identifiers.
- A response contains exactly one of `result` or `error`. An empty result object is valid; an id alone is not.
- Responses may arrive out of order. Events on a connection must be sent in increasing sequence order.
- Messages are limited to 1 MiB; the client permits at most 32 in-flight requests.
- Any request without a response within **10 seconds** closes the entire connection and fails all pending requests.
- After disconnection, the client reconnects in about 2 seconds, repeats hello and full snapshot subscription, reads the baseline, and queries pending operations. It does not automatically resend writes.

Successful response:

```json
{"jsonrpc":"2.0","id":"request-1","result":{}}
```

Business error:

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

The frontend uses the stable string in `error.data.code` and does not display arbitrary `message` text. Without a business code, `-32602` maps to `INVALID_PARAMS`, `-32601` to `UNSUPPORTED_CAPABILITY`, and other errors to `RPC_ERROR`.

## 4. Authentication, subscriptions, and device state

### 4.1 runtime.hello

Request:

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

Response:

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

All four result fields are required. `major` must be `1`; the client currently does not branch on minor, so return `0` initially. Advertise only implemented `methods`; subsequent calls are gated by this list. Omitting `runtime.subscribe` prevents the session from becoming ready. As the bootstrap method, `runtime.hello` need not list itself.

### 4.2 runtime.subscribe

Request:

```json
{"jsonrpc":"2.0","id":"sub-1","method":"runtime.subscribe","params":{"topics":["state"],"cursor":null}}
```

Response:

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

All four snapshot fields are required; use `[]` for empty lists. instanceId must match hello, subscriptionId identifies the subscription, and device IDs must remain stable across scans.

**Subscription registration and snapshot capture must share a consistent boundary.** Within the same serialized state boundary, register the subscriber, capture snapshot N, and enqueue the response before events after N. Reading a snapshot and registering later can lose intervening events. Do not hold the state lock while awaiting network sends or BLE.

Each client has its own send queue and subscriptionId. Broadcast changes to every authenticated subscriber. The frontend always sends `cursor:null`; history replay is not required for this integration.

### 4.3 runtime.event

Events are notifications without an id:

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

| type | data | Frontend behavior |
|---|---|---|
| `device.changed` | Complete Device object | Update the device projection |
| `operation.changed` | Complete Operation object; see section 6 | Update progress/terminal state and end local pending tracking |
| `configuration.changed` | At least `{"deviceId":"x1-stable-id"}` | Invalidate that device's baseline |
| `configuration.invalidated` | At least `{"deviceId":"x1-stable-id"}` | Invalidate that device's baseline |

All five event params fields are required. `sequence` must be a **decimal string in the UInt64 range**, such as `"9007199254740993"`, never a JSON number. Rust may maintain a u64 internally and stringify it on output. Sequences increase within an instance, may have gaps due to filtering, and may reset after restarting with a new instanceId.

The client ignores old instances/subscriptions and sequences no greater than the applied sequence. It buffers at most 256 events during subscription handoff. Concurrent producers must not send newer events ahead of older ones.

### 4.4 Device and connection methods

| Field | Type | Meaning |
|---|---|---|
| `deviceId` / `name` | Required string | Stable device identifier / display name |
| `connectionState` | Required string | **Only `ready` enables saving**; use `connecting` while connecting and `disconnected` when disconnected |
| `batteryPercent` | Optional integer or null | 0–100; use null for unknown, not a fabricated 0 |
| `workMode` | Optional integer or null | 0–3 when known; the actual device mode |
| `lever` | Optional string or null | `automatic` / `manual`; null when unknown, not legacy up/down numbers |

Connection request:

```json
{"jsonrpc":"2.0","id":"connect-1","method":"device.connect","params":{"deviceId":"x1-stable-id"}}
```

Disconnection uses the same params with `device.disconnect`. Both may return `result:{}`; the UI waits for device.changed. A successful request does not mean the device is already ready. Runtime discovers devices itself; there is no explicit scan method in this client.

The UI uses only the first device in its array, and device updates can change array order. Expose one target device for initial integration. There is no device.removed handler. If a device disappears, publish its disconnected projection and update the list in the next snapshot.

## 5. Configuration baselines and writes

### 5.1 configuration.get

Request:

```json
{"jsonrpc":"2.0","id":"get-1","method":"configuration.get","params":{"deviceId":"x1-stable-id"}}
```

See [configuration.json](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/contracts/runtime-v1/fixtures/configuration.json) for a full result body containing deviceId, baseToken, and configuration. baseToken is an opaque string echoed by the client; do not convert it to a number. Use a token distinguishing device state generations and configuration revisions so an old token cannot accidentally become valid after a restart.

If no trusted baseline can be established, return:

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

**Initial hardware provisioning is a prerequisite that must be addressed.** The UI disables saving when configuration is null and has no force-initialize button. If firmware cannot read back complete key/lighting configuration, do not present software defaults as known device facts. Rust can perform explicit provisioning and confirmation first, then persist a confirmed configuration record; alternatively, extend the frontend and protocol to let users explicitly initialize a device. Intended writes, old caches, and connection success alone do not prove current device configuration.

There is no field-level evidence model in this protocol. For initial integration, return a full configuration only when all four modes and global brightness are known; otherwise return null. Schema permits 1–4 modes, but the UI merely checks configuration is non-null, so the backend must still validate that the actual write scope has a safe baseline.

Reading a baseline does not load device settings into the editable draft. A subsequent save overwrites the selected scope with the local draft. Do not treat configuration.get as synchronization that replaces the frontend draft.

### 5.2 configuration.apply

See [apply.json](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/contracts/runtime-v1/fixtures/apply.json) for complete params. This script creates a full JSON-RPC request; replace example deviceId/baseToken with the values from the actual get result:

```sh
python3 - <<'PY'
import json
from pathlib import Path
params = json.loads(Path("contracts/runtime-v1/fixtures/apply.json").read_text())
print(json.dumps({"jsonrpc": "2.0", "id": "apply-1",
                  "method": "configuration.apply", "params": params}, indent=2))
PY
```

| params field | Meaning |
|---|---|
| `operationId` | UUID created and persisted by the frontend before sending; the idempotency key |
| `deviceId` | Target device |
| `baseToken` | Most recently obtained baseline token |
| `scope.deviceFields` | Currently always `["brightnessPercent"]` |
| `scope.modes` | Selected mode, such as `[0]`, or all modes `[0,1,2,3]` |
| `changes.device` | `{"brightnessPercent":60}`; range **1–100** |
| `changes.modes` | Complete keys and lights for each selected mode, not a delta |

Saving one mode also submits **global brightness**. Replace only fields and modes covered by scope; preserve other modes. Do not replace the whole device configuration with changes. scope and changes must agree, with no duplicate mode, role, or state entries.

Each mode has the shape `{"mode":0,"keys":[four keys],"lights":[nine mappings]}`. The four roles are exactly voice, approve, reject, submit. Every key requires role, action, and description. description is ASCII, at most 20 bytes, and may be empty.

The three mutually exclusive action shapes:

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

This array displays three alternatives, not a batch RPC. Use an internally tagged object with a type field, not Rust's default external shape such as `{"Shortcut":{...}}`. gui corresponds to Command and alt to Option. keyCode is a HID usage in 0–255; do not discard modifier-only combinations with keyCode=0.

A macro has 1–49 steps. delayMs is 0–765 milliseconds and a multiple of 3. The wire always uses milliseconds; firmware tick encoding belongs to the Rust device adapter. Parameterless steps contain only type, keyDown/keyUp carry keyCode, and delay carries delayMs.

Each lighting mapping is `{"state":"notification","effect":"pulseCenter"}`, not a dictionary or firmware numeric index.

| Item | Allowed values |
|---|---|
| Nine state values | `notification`, `permissionRequest`, `postToolUse`, `preToolUse`, `sessionStart`, `stop`, `taskCompleted`, `userPromptSubmit`, `sessionEnd` |
| Seventeen effect values | `off`, `middleLight`, `singleMove`, `breathing`, `rainbowMove`, `rainbowWave`, `rainbowWaveSlow`, `typingRipple`, `comet`, `scanBar`, `pulseCenter`, `warningBlink`, `successSweep`, `blueThinking`, `lowBattery`, `chargingFlow`, `approvalWait` |

### 5.3 Acceptance and device write ordering

Use a per-device serialized queue/state actor. Idempotency lookup must precede baseline checks for a new request:

```text
Authenticate and parse
→ Look up operationId
  → Same ID and business request: return original acceptance; do not write again
  → Same ID, different request: OPERATION_ID_CONFLICT
→ Validate device, scope, complete write groups, ranges, and baseToken
→ Atomically reserve device write ownership and persist the operation
→ Enqueue work and return accepted
→ Execute BLE commands and confirmation asynchronously; publish running/progress
→ Commit the trusted configuration and new baseToken; persist terminal state
→ Publish configuration.changed before operation.changed(completed)
```

The accepted operationId must match the request:

```json
{"jsonrpc":"2.0","id":"apply-1","result":{"operationId":"example-operation","status":"accepted"}}
```

Return accepted only once the backend can continue tracking the operation; do not wait for all BLE writes. Concurrent requests may queue or receive BUSY before acceptance, but baseline checking and write reservation must be free of races. Compare parsed business content for idempotency, not JSON property order or whitespace.

The device adapter handles mutual clearing of shortcut/macro layers, descriptions, lighting encoding, brightness, firmware save commands, and confirmation conditions. Handing bytes to the BLE library alone does not establish completion. Partial failures invalidate the old baseline and must not claim rollback.

## 6. Operation queries, progress, and failures

Query request and response:

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

operationId/deviceId/status are required; progress/effect/errorCode may be omitted or null. progress is a number from 0 to 1. This same structure is used in snapshot operations and operation.changed data.

| status | Suggested effect | Meaning |
|---|---|---|
| `accepted` | `none` | Accepted; device changes have not been confirmed |
| `running` | `partial` or `unknown`, according to evidence | In progress |
| `completed` | `complete` | All requirements confirmed and baseline updated |
| `failed` | `none` / `partial` / `unknown` | Failed; errorCode explains why |
| `cancelled` | `none` / `partial` / `unknown` | Backend has ended the operation; the current frontend has no cancellation RPC |

Complete partial-failure notification:

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

Hardware failures after acceptance belong in the Operation record and events. Do not return only a transient RPC error and discard the operation. The client recognizes completed, failed, and cancelled as terminal; do not rename these to success/done/error.

### 6.1 Error codes and acceptance

| Stable code | Condition | Current frontend behavior |
|---|---|---|
| `BASE_CONFLICT` | Token invalid before acceptance | Clear this pending request and require a baseline reload |
| `BUSY` | Device queue cannot accept work before acceptance | Same as above |
| `DEVICE_NOT_READY` | Device not ready before acceptance | Same as above |
| `INVALID_PARAMS` | Invalid parameters before acceptance | Same as above |
| `UNSUPPORTED_CAPABILITY` | Unsupported feature before acceptance | Same as above |
| `INCOMPLETE_WRITE_GROUP` | Required configuration group incomplete before acceptance | Same as above |
| `OPERATION_ID_CONFLICT` | Same ID with a different request | Keep tracking and query; do not assume no device write occurred |
| `OPERATION_NOT_FOUND` | Historical operation cannot be found | Show unknown result and retain pending state |
| `DEVICE_TIMEOUT` and other hardware failures | errorCode on an accepted operation | A failed Operation ends tracking and invalidates the writable baseline |

**The first six codes are a fixed allowlist the frontend interprets as definitely not accepted.** Never use them to report a failure after acceptance. Adding another pre-acceptance rejection code requires updating the frontend; otherwise it retains the pending operation and queries the result.

### 6.2 Persistence and restart recovery

Before sending, the frontend persists the original apply request and operationId. After a lost acceptance response or Runtime restart, it queries that same ID without creating a new ID and replaying the write. Persist request identity, operation status, device effects, and configuration revisions on the server.

Operation records must survive WebSocket disconnects; production Runtime should recover them after process restarts. The backend must define retention; the wire contract currently sets no number of days. After expiry, return OPERATION_NOT_FOUND rather than equating missing records with proof of non-execution.

For operations found in progress after restart, recover through hardware-verifiable facts or end them as failed with unknown effects and invalidate configuration. Do not repeat the entire write without evidence. Even after a user manually acknowledges an unknown result and stops frontend tracking, a trusted baseline must be reloaded before another save.

## 7. Rust boundaries and serialization

Suggested module responsibilities; existing Rust code need not adopt these names:

| Module | Responsibility |
|---|---|
| `ipc/discovery` | Listener address, private token file, atomic updates |
| `ipc/session` | WebSocket, authentication state, JSON-RPC dispatch, per-connection send queue |
| `ipc/wire` | Wire DTOs matching Schema and stable error codes |
| `runtime/state` | Snapshots, monotonic sequence, subscription registration, broadcasts |
| `runtime/configuration` | Trusted baseline, baseToken, scope checks, revisions |
| `runtime/operations` | Idempotency index, persistence, queries, per-device execution |
| `device/*` | BLE/firmware protocol, ACKs, timeouts, device state evidence |

Do not expose BLE structs or database records directly as IPC DTOs. Rust snake_case fields must use the documented camelCase names on the wire. Use the type discriminator for actions and macro steps. With Serde, explicitly configure variant and field names, especially keyDown/keyUp/releaseAll/noOp/keyCode/delayMs; Rust identifiers do not automatically match the contract.

Represent sequence as a string in wire DTOs and validate it as u64 internally. baseToken/operationId/deviceId remain opaque strings. Optional fields may be null or omitted; required arrays cannot be null. After decoding DTOs, validate unique roles/states, scope consistency, and device limits.

Do not put local file paths, firmware Flash addresses, RGB565 data, BLE packet numbers, or localized UI text into configuration. Selected GIFs stay local to Studio and are not uploaded to Rust.

## 8. Integration steps

### 8.1 Verify the frontend with the existing fixture

From the Studio repository root:

```sh
python3 scripts/mock-runtime-server.py
```

stdout prints the temporary discovery file path. In Xcode select **Studio Frontend**, then Edit Scheme → Run → Arguments → Environment Variables:

```text
AHAKEY_RUNTIME_DISCOVERY = absolute path printed above
```

Run the app, inspect device state, change brightness, save, and observe completed. This Python service is a protocol fixture without real BLE, production persistence, or complete multi-client broadcasting.

### 8.2 Switch to Rust

1. Quit the legacy AhaKey Studio/device backend so Rust is the sole owner of the target device.
2. Start Rust and have it publish the agreed discovery file.
3. Point Xcode's environment variable to that file, or remove the test override when using the default path.
4. Use **Studio Frontend**, not **Studio Frontend Mock**, which bypasses WebSocket.
5. Verify hello → subscribe → configuration.get. Save once the device is ready and the baseline is trusted.
6. Compare Rust logs and actual device behavior; get after completed must return the new baseToken.
7. Disconnect WebSocket during a save, then reconnect. operation.get must recover the original operation without duplicate BLE writes.

After building, launch directly from a shell to inherit the environment variable:

```sh
AHAKEY_RUNTIME_DISCOVERY="/absolute/path/to/discovery.json" \
  "DerivedData/Frontend/Build/Products/Debug/Studio Frontend.app/Contents/MacOS/Studio Frontend"
```

### 8.3 Automated checks and acceptance

Run existing frontend tests from the Studio repository root:

```sh
xcodebuild -project "AhaKey Studio.xcodeproj" -scheme "Studio Frontend" \
  -configuration Debug -destination "platform=macOS,arch=arm64" \
  -derivedDataPath DerivedData/Frontend \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual test
```

Use arch=x86_64 on Intel Macs. The existing WebSocket test starts its own Python fixture; **it does not automatically test a running Rust service**. Add Rust integration tests or verify the following acceptance cases.

| Check | Required observation |
|---|---|
| Wrong token / business call before hello | Rejected without state disclosure |
| Four existing fixtures | Rust decodes them and re-encodes equivalent structures and field semantics |
| Sequence beyond JS safe integer range | `9007199254740993` preserved exactly without floating-point rounding |
| Device changes during snapshot handoff | No event gap; final client projection is correct |
| Single-mode save | Selected mode and global brightness change; other modes remain intact |
| Same ID and request repeated | Original acceptance returned, only one device execution |
| Same ID with different request | OPERATION_ID_CONFLICT; original operation retained |
| Save with stale token after external change | BASE_CONFLICT with no additional device writes |
| Disconnect / acceptance response lost | Original operationId queryable; no automatic client replay |
| BLE failure mid-write | failed + partial/unknown; old baseline invalidated |
| Runtime restart during execution | New instanceId; recover operation or honestly report unknown without blind replay |
| Two subscribers | Each receives change events with its own subscription identity |
| New device without readback | configuration=null; explicit provisioning precedes saving |

[schema.json](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/contracts/runtime-v1/schema.json) currently contains only `$defs`, with no root `$ref`. Select the definition when validating each fixture; treating the entire file as the root schema would impose no constraints. Map hello.json → Hello, subscription.json → Subscription, configuration.json → ConfigurationDocument, and apply.json → Apply. Rust business tests must also cover uniqueness, complete write groups, idempotency, and concurrency.

## 9. Current frontend limitations and troubleshooting

| Symptom | Check first |
|---|---|
| Always offline | Discovery path, owner/0600, loopback IP, active listener, token, major=1, and runtime.subscribe in methods |
| Disconnect after about 10 seconds | RPC blocked by BLE work, delayed accepted response, or incorrectly echoed id |
| Device visible but saving disabled | ready state, non-null configuration, pending operations, external changes, draft validation, advertised apply |
| Events ignored | runtime.event method, matching instanceId/subscriptionId, increasing string sequence, complete data |
| Baseline still invalid after save | Commit baseline first; prefer configuration.changed before completed so a late event does not invalidate the completion-triggered get |
| Unknown result | Original ID missing from operation.get; inspect persistence, restart recovery, and retention |

The frontend automatically attempts a baseline read only after establishing the Runtime session and after its own operation completes. If the initial device list is empty, a device appears/becomes ready later, or an external configuration.changed arrives, the user may need **Reload baseline**. These cases do not yet have automatic baseline refresh. Do not work around this by fabricating ready state or default configuration.

OLED/GIF uploads, physical lighting previews, Hook management, voice hosting, text injection, firmware flashing, multi-device selection, device mode switching, and writes with partially unknown field state are not supported yet. Changing the editing mode tab only changes the draft scope. Adding those capabilities requires frontend interfaces, Rust implementations, and fixtures together; advertising a method does not create UI support.

## 10. Related code

- [Contract summary](../contracts/runtime-v1/README.md) and [JSON Schema](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/contracts/runtime-v1/schema.json)
- [Swift wire DTOs](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/StudioFrontend/Runtime/RuntimeDTOs.swift) and [WebSocket client](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/StudioFrontend/Runtime/IPCRuntimeClient.swift)
- [Subscription/event projection](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/StudioFrontend/State/RuntimeStore.swift) and [save/recovery logic](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/StudioFrontend/State/StudioModel.swift)
- [Draft-to-wire conversion](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/StudioFrontend/State/StudioDraftStore.swift)
- [Runnable Python WebSocket fixture](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/scripts/mock-runtime-server.py) and [frontend tests](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/Tests/StudioFrontendTests/RuntimeTests.swift)
- [Legacy device protocol](ble-protocol.md) and [legacy firmware encoding](https://github.com/AhakeyAI/AhaKey-Studio-mac/blob/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c/AhaKey%20Studio/Services/Bluetooth/LegacyDraftEncoding.swift), for device adapter reference only
