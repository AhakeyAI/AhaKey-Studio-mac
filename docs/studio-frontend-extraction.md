# Extracting the Studio frontend from origin

**English** · [简体中文](zh/studio-frontend-extraction.md) · [日本語](ja/studio-frontend-extraction.md)

> Branch scope: this guide describes the Studio/Rust implementation on [`dev`](https://github.com/AhakeyAI/AhaKey-Studio-mac/tree/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c). The `main` branch receives documentation only in this change. Run frontend commands from a checkout of that implementation; its source, fixtures, and build targets are not included in this documentation branch.

Reviewed on 2026-09-20. This document records the initial investigation and overall extraction plan. The first stage has since been implemented on `dev`; see [standalone frontend development](studio-frontend.md) for the actual source layout, running instructions, and remaining scope. Rust and hardware integration have not yet been tested.

## Baseline and conclusion

- `git fetch origin` was run against `AhakeyAI/AhaKey-Studio-mac`; `origin/main` was at `2f77109`.
- At review time, local `main` was at `bdec7b3`, two commits behind. The differences concerned Japanese localization, related Xcode project settings, and localization documentation. The Swift source reviewed here matched origin/main.
- The Rust repository HEAD was `a4e4b29`, and its working tree implementation was inspected. It had initial BLE discovery, connection, subscription, command writes, and state parsing, but no IPC endpoint for Studio.
- `cargo check --locked --offline` failed: `src/ahakey/model_x1.rs:25` assigned `None` to a `listener` declared as `JoinHandle<()>`. This was a build blocker; fixing it alone would not complete Runtime.
- The existing untracked `runtime-studio-current-desktop-design.md` was an earlier draft. Its description of Rust as only scanning and printing was outdated. Its responsibility boundaries remained useful, but it was not an implemented contract.

Keep the existing SwiftUI Studio and let a separate Rust Runtime own the device connection. Extract the frontend and a replaceable Runtime interface first, then connect the real Rust implementation. This repository has already been extracted from the multi-platform Desktop project into a macOS project; the main remaining task is to separate responsibilities currently coupled within one process.

This design assumes the frontend continues to use SwiftUI. A web or cross-platform UI would require a separate implementation of the keyboard canvas and SwiftUI pages. Choosing Rust for the backend does not itself require rewriting the UI.

## Target structure

```text
Studio (SwiftUI process)
  Views / VibeBar / permission guidance / account pages
      ↓
  StudioModel
    ├─ StudioDraftStore: editable drafts, local assets, selection
    ├─ RuntimeStore: backend snapshots, device state, operation progress
    └─ RuntimeClient: application requests, subscriptions, reconnection
             ↓ Local IPC
Rust Runtime (separate background process)
  Device connection / state / configuration / assets / Hooks / flashing
             ↓
           Keyboard

macOS capabilities: voice, input monitoring, text injection
  Keep Swift implementations during migration; host them separately
  when they must continue running after Studio exits.
```

Closing Studio should not terminate Rust Runtime or its accepted device operations. An installer can still distribute Studio, Runtime, and helper programs together. Separate processes, separate builds, and separate installers are independent choices.

## Existing coupling and file ownership

Paths below are relative to the repository root. Line numbers describe the source at the time of the initial review.

| Location | Existing behavior | Extraction action |
|---|---|---|
| `AhaKey Studio/App/AhaKeyWorkspaceView.swift:6` | The workspace directly creates the BLE manager | Inject an app-level `StudioModel` to coordinate connection lifetime |
| `AhaKey Studio/App/RootView.swift:5` | Pages and permission guidance depend on the BLE manager | Read Runtime device/permission projections; keep System Settings navigation in the platform layer |
| `AhaKey Studio/Features/Studio/AhaKeyStudioView.swift:9` | 5,057 lines with direct BLE, Agent, voice, and account dependencies | Extract behavior and state, then split the canvas, inspector, status bar, and other views |
| Same file, `:2185`, `:2322` | Uploads images, assembles commands, waits for ACKs, and saves to the device | Submit configuration intent from the frontend; move execution order and confirmation rules into Rust |
| Same file, around `:2090` | Hands BLE ownership between Studio and Agent | Remove the interaction and transitional state after Rust takes ownership |
| Same file, around `:2410` | The view automatically uploads default OLED assets after connecting | Make default asset installation an explicit Runtime policy, not a hardware write triggered by view appearance |
| `AhaKey Studio/Features/Studio/AhaKeyStudioModels.swift` | Mixes presentation, draft persistence, and firmware byte models | Keep presentation and drafts; introduce separate request/response DTOs and move firmware encoding out |
| `AhaKey Studio/Services/Bluetooth/AhaKeyBLEManager.swift` | Mixes BLE, Agent file polling, and notifications | Remove BLE/polling from the frontend; make presentation such as `SwitchStateNotifier` subscribe to RuntimeStore |
| `AhaKey Studio/Services/Bluetooth/AhaKeyProtocol.swift` | Command codecs, `IDEState`, and `HIDUsage` share a file | Move codecs to Rust and extract state names and key-code display into frontend domain/presentation modules |
| `AhaKey Studio/Features/OLED/OLEDFrameEncoder.swift` | Encodes GIFs into device pixels | Put device encoding in Rust; keep file selection and animation preview in Studio |
| `AhaKey Studio/Services/Agent/AgentManager.swift` | 1,802 lines covering ownership handoff, installation, startup, and Hook changes | Separate Runtime installation/startup, move Hook management to the backend, and remove ownership handoff |
| `Tools/Agent/` | Legacy Swift daemon and tool Hooks | Migrate execution; a forwarding-only Hook CLI may remain during compatibility, without owning BLE |
| `AhaKey Studio/Features/Studio/VibeBarBridge.swift:11` | Directly subscribes to BLE and voice singletons | Subscribe to RuntimeStore/voice state; retain `Modules/VibeBar` |
| `AhaKey Studio/Features/Firmware/` | Views create the flasher and run `wchisp` | Keep interaction and progress display; move preflight, erase/write, and process management to Runtime |
| `Modules/AhaKeyPluginKit/PluginHost.swift:126` | Queries the lever through legacy `/tmp/ahakey.sock` | Replace with a Runtime adapter while retaining the plugin stdio protocol |
| `sdks/typescript/` | Currently a plugin SDK | Do not treat it as an implemented Runtime SDK; add a Runtime client separately |
| `AhaKey Studio/Features/Account/` | Cloud account interaction | Retain initially; device extraction does not require moving registration or payments to Rust |
| `AhaKey Studio/Features/Voice/`, `AppDelegate.swift` | The app starts voice listening and executes macOS capabilities | Isolate platform implementations; if initially kept in-process, make it clear that voice stops when Studio exits |

Do not copy every `AhaKeyBLEManager` method into an RPC. That would keep byte commands, Flash addresses, write ordering, and recovery details in the frontend.

## Frontend modules to implement first

Start with ordinary directories and a small number of explicit targets. A separate Swift package for every directory is unnecessary.

```text
AhaKey Studio/
  App/                         # App assembly, windows, menus
  Features/                    # Editing and presentation
  Models/                      # Frontend domain models and display conversion
  State/
    StudioModel.swift          # User actions; coordinates drafts and backend state
    StudioDraftStore.swift     # Legacy data migration and unsaved edits
    RuntimeStore.swift         # Authoritative projections, separate from drafts
  Runtime/
    RuntimeClient.swift        # Application-level Swift interface
    RuntimeDTOs.swift          # Wire data without SwiftUI/CoreBluetooth
    IPCRuntimeClient.swift     # Real IPC adapter
    MockRuntimeClient.swift    # Offline development adapter
  Platform/macOS/             # Settings navigation, voice, platform integration
  Resources/
  Localization/
```

Mock and IPC implementations share one application interface. A temporary Legacy adapter may preserve the old application during migration, but it must only run in an explicitly selected legacy mode. Rust mode must not start a Swift BLE owner or automatically fall back to direct device access after disconnecting.

## Initial interface scope

Follow the earlier design's local WebSocket + JSON-RPC direction. Freeze the following semantics and JSON fixtures before implementing both ends. Method names in this section are proposals, not claims about current Runtime capabilities.

| Method family | Frontend requirement |
|---|---|
| `runtime.hello`, `runtime.subscribe` | Version and capability negotiation; atomic snapshot and subsequent events |
| `device.discover/connect/disconnect` | Submit connection intent; distinguish IPC connectivity from device connectivity |
| `configuration.get/apply` | Read configuration with a baseline, submit changes, and return operationId |
| `operation.get` | Query the same operation after reconnecting instead of blindly replaying writes |
| `device.preview/endPreview` | Temporary preview, with Runtime responsible for timeout and restoration |

Deliver state display and configuration saving without images first. Add assets, Hooks, voice, and flashing incrementally, and do not advertise unimplemented methods.

The interface must make these points explicit:

- Runtime connectivity, keyboard state, and user drafts are separate. Unknown battery/lever values must not be filled with 0.
- `configuration.apply` carries shortcut/macro/disabled actions, descriptions, lighting effects, and other domain fields, not BLE bytes or the existing `StudioDraft` wholesale.
- The existing draft model stores macro delays in 3ms units. Conversion to milliseconds requires an explicit migration. Firmware lighting numbers must not drive device execution in the UI.
- Brightness is device-level configuration. Although the existing draft stores it per mode, the command itself has no mode parameter.
- `localAssetPath`, localized text, and UI state do not cross the process boundary. Uploaded assets are referenced by resourceId.
- Acceptance is not execution success. Runtime owns progress; preserve operationId, baseline conflict, and partial-failure semantics.
- After IPC loss, restore backend projections from a new snapshot while preserving unsaved drafts. Neither defaults nor the last submitted values count as device readback.
- Define endpoint discovery, authentication, protocol versions, and the actual permission-owning process together, rather than only declaring a fixed port.

## Implementation stages and acceptance

These stages record the original plan. Stage 1 was subsequently implemented on local `dev` at the user's request; the architecture document has also been updated.

1. **An independently runnable frontend.** The original proposal used a `codex/studio-frontend` branch from updated origin/main; actual work used `dev`. Retain Chinese, English, and Japanese app resources. Extract DTOs, stores, RuntimeClient, and Mock so pages no longer read the BLE manager directly. With Runtime absent, the app opens, edits drafts, and shows unavailability; Mock demonstrates connections, progress, and failures.
2. **Rust state integration.** Fix the build, then implement hello/subscribe, real device connections, and state notifications. Stop the old BLE owner before Rust takes over. Retain the legacy release as a rollback option during transition and avoid running two device owners at once.
3. **Configuration workflow.** Migrate configuration without images, mutual clearing of macro/shortcut layers, key descriptions, lighting, global brightness, and per-command ACKs. Studio submits configuration and displays operations. Then remove BLE ownership switching from the main UI.
4. **Remaining functionality.** Add OLED assets and preview, Hook/plugin queries, then flashing. Isolate the voice host and keep permission guidance aligned with the executing process. Correct implicit behavior such as default OLED uploads and draft edits immediately changing voice routing.
5. **Build and release cleanup.** Remove the Studio build dependency on the old `AhaKeyConfigAgent` and `Embed Agent`. Migrate flashing resource copy/validation steps and update CI, installation, and architecture documentation. The architecture document described the old multi-platform tree at the time of the initial review.

Xcode uses filesystem-synchronized directories. Moving old implementations into `AhaKey Studio/Legacy` alone does not exclude them from compilation. Move them outside the synchronized root, configure target membership exceptions, or put them in an explicit Legacy target, and update dependent tests.

Stage 1 produces a frontend that can be developed independently. It can replace the full release only after real device integration is complete. Unconnected features must remain visibly unavailable; a successful Mock operation must never be presented as a successful hardware write.

## Completion criteria

- The frontend target excludes CoreBluetooth, device command codecs, Flash layout, and legacy Agent connection polling.
- In real mode, Rust is the sole device owner. Background connections and accepted operations continue after Studio closes.
- Swift and Rust verify the contract using the same JSON fixtures; the frontend and Mock can be built and developed independently.
- Reconnection preserves drafts and does not duplicate writes. External changes produce conflicts, and unknown results are displayed differently from successful writes.
- Hardware tests cover saving one/all modes, conversion between macros and shortcuts, disconnection during OLED transfer, concurrent Hooks and configuration, and non-cancellable flashing stages.
- Voice process lifetime, permission ownership, and frontend guidance agree. Migration of old drafts, asset paths, and user integrations is traceable.

The initial investigation only reviewed source, remote differences, and the Rust build check. Stage 1 was then implemented on a local `dev` branch as requested. No device commands or firmware flashing were performed.
