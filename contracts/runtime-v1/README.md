# Studio frontend phase-one contract

**English** · [简体中文](README.zh-CN.md) · [日本語](README.ja.md)

> Branch scope: this guide describes the Studio/Rust implementation on [`dev`](https://github.com/AhakeyAI/AhaKey-Studio-mac/tree/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c). The `main` branch receives documentation only in this change. Run frontend commands from a checkout of that implementation; its source, fixtures, and build targets are not included in this documentation branch.

This is the interface subset consumed by `StudioFrontend/Runtime` and verified with a Mock and a separate WebSocket fixture. Rust Runtime has not yet implemented this interface; this directory is not proof of hardware compatibility. The broader features in earlier `docs/runtime-studio-*.md` documents remain future design work. This directory specifies the fields the current frontend actually sends and reads.

`schema.json` defines the wire data, and `fixtures/` contains fixed JSON examples. Rust integration should use the same fixtures for deserialization tests; do not rely on a language's default enum serialization. In this stage, `Apply.changes.modes[].lights` is an array of `{state,effect}` objects. Any extended model requires coordinated changes to the protocol version, both DTO implementations, and the fixtures.

For Rust implementation and integration steps, see the [Rust backend integration guide](../../docs/rust-backend-integration.md).

## Connection

The client reads a discovery file private to the current user:

```json
{"endpoint":"ws://127.0.0.1:12345/","token":"example-only"}
```

The default path is `~/Library/Application Support/AhaKey/runtime/discovery.json`; `AHAKEY_RUNTIME_DISCOVERY` can point to another file. It must be a regular file owned by the current user, inaccessible to other users (0600 recommended), and smaller than 16 KiB. Only `ws` addresses using loopback IPs are accepted. URL credentials, query strings, fragments, and HTTP redirects are rejected. A real server must also validate authentication, Origin, and client permissions.

Each WebSocket text message contains one JSON-RPC 2.0 object. Request ids are strings. Text messages are limited to 1 MiB, with at most 32 in-flight requests and a 10-second request timeout. The frontend uses one receive loop and serialized sends, matching out-of-order responses by id.

The first request is `runtime.hello`:

```json
{"jsonrpc":"2.0","id":"hello-1","method":"runtime.hello","params":{"protocol":{"major":1,"minor":0},"client":{"name":"AhaKey Studio","version":"0.1.0","kind":"studio"},"token":"example-only"}}
```

See `fixtures/hello.json` for the result shape. The major version must be 1. `methods` must list only methods that are actually supported.

## Methods and events

| Method | params | result |
|---|---|---|
| `runtime.subscribe` | `{"topics":["state"],"cursor":null}` | `Subscription` |
| `configuration.get` | `{"deviceId":"..."}` | `ConfigurationDocument` |
| `configuration.apply` | `Apply` | `{"operationId":"...","status":"accepted"}` |
| `operation.get` | `{"operationId":"..."}` | `Operation` |
| `device.connect` / `device.disconnect` | `{"deviceId":"..."}` | Any JSON result; the frontend ignores its fields and waits for state events |

The backend discovers devices and includes connection candidates in the snapshot. The first UI version uses the first device in that snapshot. Explicit scanning and multi-device selection are not implemented. Rust integration can initially expose one known X1.

Register a subscription and capture its snapshot atomically. Send the response before events newer than that snapshot:

```json
{"jsonrpc":"2.0","method":"runtime.event","params":{"subscriptionId":"...","instanceId":"...","sequence":"9007199254740994","type":"device.changed","data":{"deviceId":"x1","name":"AhaKey","connectionState":"ready","batteryPercent":null,"workMode":0,"lever":"manual"}}}
```

- `device.changed` carries a complete `Device` projection. Saving requires connectionState ready. Lever strings are automatic/manual; unknown values remain unknown in the UI.
- `operation.changed` carries a complete `Operation`. status is accepted/running/completed/failed/cancelled; effect can be none/partial/unknown/complete.
- `configuration.changed` / `configuration.invalidated` include at least deviceId and prevent saving against an old baseline.
- `sequence` is a UInt64 decimal string. Tests cover values larger than JavaScript's safe integer range. Filtered global sequences may have gaps.
- The frontend buffers events during the subscription response handoff and ignores stale subscriptions, instances, and sequence numbers. Reconnection always requests a fresh snapshot and does not depend on event replay.

## Configuration and operations

A save includes all four key bindings and nine IDE state lighting mappings for each selected mode, plus device-level brightness. scope must match changes; the backend must reject duplicate mode, role, or state entries. Key action is shortcut/macro/disabled; modifiers use control/shift/alt/gui; keyCode is a HID usage; macro delayMs is in milliseconds. The backend remains responsible for enforcing X1 limits: ASCII descriptions up to 20 bytes, macros up to 49 steps, and delays that are multiples of 3ms and no greater than 765ms. Frontend checks do not replace backend validation.

When the full configuration cannot be established, `configuration.get` returns `configuration:null`. The frontend retains the draft and disables saving instead of presenting defaults as device facts. This stage cannot write partially unknown fields; that requires an extended model for field evidence.

operationId is persisted locally before sending. The same ID and content must be deduplicated; different content returns OPERATION_ID_CONFLICT. Losing the acceptance response does not automatically replay a write. After reconnection, the client queries the same ID. OPERATION_NOT_FOUND means the result is unknown. Even after the user checks the device and stops tracking the operation, the baseline must be reloaded before another save.

completed means all backend-defined configuration confirmation conditions have been met. The frontend does not calculate ACK completion or treat accepted as success. Partial failures must report effect=partial/unknown and must not claim rollback. The backend must define operation retention and unknown-result semantics after restart.

Errors use JSON-RPC error with a stable application code in `error.data.code`, such as BASE_CONFLICT, DEVICE_NOT_READY, DEVICE_TIMEOUT, BUSY, INCOMPLETE_WRITE_GROUP, or OPERATION_NOT_FOUND. The frontend does not display arbitrary server error.message values. Standard errors -32602/-32601 map to INVALID_PARAMS/UNSUPPORTED_CAPABILITY respectively.

Asset uploads, device previews, Hooks, voice hosting, firmware flashing, and the full permission model are outside this subset. Selected GIFs remain in the Studio draft and are not sent with configuration.apply. Device Flash addresses, RGB565, packet sizes, and firmware encoding are not part of this interface.

## Local integration

Run `python3 scripts/mock-runtime-server.py`. It prints a temporary discovery file path to stdout. Set that path as Xcode's `AHAKEY_RUNTIME_DISCOVERY` environment variable, then run the `Studio Frontend` scheme. This server is a single-client integration fixture without multi-client broadcasting, production storage, hardware validation, or asset uploads. Do not distribute it as the real Runtime.

`StudioFrontendTests.testRealWebSocketClientAgainstPythonFixture` starts this server automatically to verify a real URLSession WebSocket handshake, authentication, configuration reads and writes, events, and operation queries. The test stops the server when finished.
