# Standalone Studio frontend development

**English** · [简体中文](zh/studio-frontend.md) · [日本語](ja/studio-frontend.md)

> Branch scope: this guide describes the Studio/Rust implementation on [`dev`](https://github.com/AhakeyAI/AhaKey-Studio-mac/tree/5eb399c93c838c6047e3975f3dfdaf4d346c4b7c). The `main` branch receives documentation only in this change. Run frontend commands from a checkout of that implementation; its source, fixtures, and build targets are not included in this documentation branch.

`dev` was created from `origin/main` at `2f77109`. This change implements the first stage of frontend extraction, retaining the legacy application as a migration reference. The Rust repository was not modified.

Rust backend developers should start with the [Rust Runtime integration guide](rust-backend-integration.md), which covers server setup, full interface semantics, initial provisioning constraints, and integration acceptance checks.

## Running the app

Open `AhaKey Studio.xcodeproj` in Xcode:

- **Studio Frontend Mock**: runs without hardware or a backend. Edit key bindings, macros, lighting effects, global brightness, and local GIFs across four modes. A visible MOCK banner identifies this mode. The menu can simulate disconnection, a lost acceptance response, a partial write failure, and an external configuration change.
- **Studio Frontend**: the real IPC client. It reads the current user's Runtime discovery file. When the backend is unavailable, draft editing remains available and the client automatically retries the connection. It does not start the legacy Agent or fall back to Swift BLE.
- **AhaKey Studio**: the existing full application, retaining its Swift backend and Bluetooth implementation as a migration reference. Stop the legacy device owner before handing real hardware to Rust.

Command-line validation:

```sh
python3 scripts/check-frontend-boundary.py
python3 scripts/check-localizations.py
xcodebuild -project "AhaKey Studio.xcodeproj" -scheme "Studio Frontend" \
  -configuration Debug -destination "platform=macOS,arch=arm64" \
  -derivedDataPath DerivedData/Frontend \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual test
```

On Intel Macs, change arch to x86_64. The Mock scheme passes `--mock-runtime`; the built application also accepts this argument when launched directly.

## Code responsibilities

| Location | Responsibility |
|---|---|
| `StudioFrontend/App` | Independent app lifecycle and projection of Runtime state into VibeBar |
| `StudioFrontend/Views` | Page layout and editing interactions without hardware calls |
| `StudioFrontend/State/StudioDraftStore.swift` | Draft persistence, global brightness, and conversion from drafts to configuration intent |
| `StudioFrontend/State/RuntimeStore.swift` | Snapshot and event projection, sequence and subscription isolation, and invalidation after external changes |
| `StudioFrontend/State/StudioModel.swift` | Connection recovery, configuration baselines, persisted pending operations, and result queries |
| `StudioFrontend/Runtime` | DTOs, application interface, in-memory Mock, and real WebSocket adapter |
| `AhaKey Studio/SharedPresentation` | Keyboard canvas, shortcut editor, GIF preview, account page, HID display, and IDE state shared by both targets |
| `AhaKey Studio/Services/Bluetooth/LegacyDraftEncoding.swift` | Firmware lighting and macro byte encoding used only by the legacy target |
| `contracts/runtime-v1` | Current frontend contract subset, JSON Schema, and fixed examples |

The new target's only target dependency is VibeBar. It does not include the old Agent, CoreBluetooth, OLED device encoding, or flashing programs. Shared source files are explicitly added to the new target to avoid compiling the entire legacy source root. CI runs source boundary checks and standalone frontend tests.

## State and data

The locally selected editing mode is separate from the device's actual mode; changing tabs does not change the keyboard's working mode. Selecting a GIF or changing a lighting effect only updates the draft and local preview. Only saving configuration submits a backend request.

Mock and real modes use separate UserDefaults domains: `ai.ahakey.studio.frontend.mock` and `ai.ahakey.studio.frontend`. On first launch, real mode copies the legacy `ahakey.studio.draft.v1` without modifying it. Debug prefers the legacy `.debug` domain; Release uses the legacy production domain. Legacy preferences are not changed. Brightness is extracted from legacy Mode 0 into a device-level field. Once a new draft exists, subsequent legacy data does not overwrite it.

Newly imported GIFs are copied to `~/Library/Application Support/AhaKey/StudioFrontend/Assets`; local paths are not sent to Runtime. Custom asset paths in legacy drafts are retained. If the original file no longer exists, select it again. Legacy mode nicknames, Hook policies, and voice routing have not been migrated and remain managed by the old application.

Backend state does not overwrite drafts. External configuration changes block saving. After reviewing the change, the user can reload the baseline while keeping the draft; the next save explicitly overwrites the selected scope. If the user continues editing during a save, its completion only updates the backend baseline and does not incorrectly mark later edits as saved.

The operationId and original request are recorded before sending. After a disconnection or lost response, the client queries the original operation and never automatically resends configuration. A partial failure clears the writable baseline. When an operation cannot be found, its result remains unknown and the user must check the device. Closing Studio only closes the client connection; it does not send stop or cancellation requests to Runtime.

## Current scope

The in-memory Mock and a separate Python WebSocket fixture are connected. Tests cover real WebSocket transport and message parsing, but integration with Rust Runtime or hardware has not yet been tested. Rust must implement the [current contract subset](../contracts/runtime-v1/README.md).

Configuration saves currently cover key bindings, lighting effects, and global brightness. OLED uploads, physical lighting previews, Hook management, voice listening, text injection, and firmware flashing await later Runtime integration; the UI identifies these limitations. The account page reuses the existing cloud implementation. The frontend does not request Bluetooth, microphone, or input monitoring permissions.

The UI currently shows only the first device in the snapshot, with no explicit scan command or multi-device selector. Unknown battery and lever values remain unknown. Complete the Rust connection, state, and configuration workflow first, then migrate the remaining backend capabilities before replacing the legacy release target.
