# Architecture

**English** · [简体中文](zh/architecture.md) · [日本語](ja/architecture.md)

> Branch scope: this guide describes the Studio/Rust implementation on [`dev`](https://github.com/AhakeyAI/AhaKey-Studio-mac/tree/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c). The `main` branch receives documentation only in this change. Run frontend commands from a checkout of that implementation; its source, fixtures, and build targets are not included in this documentation branch.

This repository contains the Xcode project for macOS Studio. References in older documents to Windows, Linux, a BLE TCP bridge, or a root `Package.swift` describe the former Desktop monorepo, not this repository.

## Two application entry points

`AhaKey Studio` is the full Swift application from before the migration. It includes device configuration, voice, accounts, firmware flashing, and the background daemon and Hook CLI under `Tools/Agent`. It still manages hardware through Swift CoreBluetooth and retains the legacy device connection ownership handoff between Studio and the daemon.

`Studio Frontend` is the new SwiftUI client for a separate Rust Runtime. Its source target excludes BLE, the old Agent, firmware command encoding, and the flashing executor. Developers can run it without hardware through the `Studio Frontend Mock` scheme. Real mode uses a local WebSocket connection with JSON-RPC; see the [current contract](../contracts/runtime-v1/README.md). The Rust implementation lives in a separate repository and has not yet completed integration testing.

```text
Studio Frontend → StudioModel → RuntimeClient → Local IPC → Rust Runtime → Keyboard
                      ├─ StudioDraftStore: user drafts
                      └─ RuntimeStore: backend state and operation results
                                   └─ RuntimeVibeBarBridge → VibeBar
```

Rust Runtime is intended to own the device connection and execute configuration, asset uploads, Hooks, and firmware flashing. Closing Studio only closes its client connection; it does not terminate Runtime. The current Mock and fixture do not establish that these backend capabilities have been implemented.

## Source layout

| Directory | Purpose |
|---|---|
| `StudioFrontend/` | New application entry point, views, drafts, backend state, IPC, and Mock |
| `AhaKey Studio/App`, `Features`, `Services` | Legacy entry point and full implementation; the new target explicitly reuses a small set of pure models and account code |
| `AhaKey Studio/SharedPresentation` | Shared keyboard canvas, shortcut editor, GIF preview, account page, and display models |
| `Modules/VibeBar` | Shared macOS overlay UI |
| `Modules/AhaKeyPluginKit`, `sdks/typescript` | Existing plugin host and stdio JSON-RPC SDK; these are not yet a Runtime SDK |
| `Tools/Agent` | Legacy Swift daemon and tool Hook CLIs |
| `contracts/runtime-v1` | Protocol schema and fixtures consumed by the new frontend |
| `Tests/StudioFrontendTests` | Frontend state, operation recovery, and integration with a real WebSocket fixture |

## State and execution constraints

- Studio drafts and Runtime authoritative state are stored separately. Selecting an editing mode does not switch the device's actual mode.
- The frontend submits configuration intent; it does not assemble BLE bytes, Flash addresses, or device write sequences.
- Snapshots and events restore state. A request id pairs responses within a connection; operationId supports operation queries across connections.
- An expired configuration baseline blocks saving. Unknown state is not replaced with a default battery level or automatic approval state.
- Stop the legacy BLE owner before Rust takes over real hardware. The new frontend never automatically enables the old Bluetooth implementation when IPC fails.
- macOS voice, input injection, and permissions belong to the process executing them. The new frontend does not currently start these capabilities.

See [standalone frontend development](studio-frontend.md) for running the app, data migration, and current limitations, and the [extraction plan](studio-frontend-extraction.md) for the full migration roadmap. Neither the cloud account service nor the Rust backend is implemented in this repository.
