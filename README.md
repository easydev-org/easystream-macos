# easystream-macos

The macOS easystream daemon (`est://` video/input + the HTTP a11y API and web
UI). Zero third-party dependencies — only Apple system frameworks.

## Build

**On macOS only.** The daemon links Darwin-only frameworks (`ScreenCaptureKit`,
`VideoToolbox`, `AppKit`, `ApplicationServices`) and Swift has no macOS
cross-toolchain on Linux, so this one is *not* built in a container (unlike the
Linux/Windows Rust daemons, which have a `Containerfile.build`).

```sh
./build.sh          # fetch the shared web UI, then swift build -c release
# -> .build/release/easystream
```

`build-webui.sh` pulls the UI from the single source of truth
(`easydev-org/easystream-webui`) and **generates** `Sources/a11y/Assets.swift`.
Swift has no `include_str!`, and the daemon is boot-fetched as a *single*
executable (a SwiftPM resource bundle would not travel), so the UI is inlined as
string literals. Neither the UI nor `Assets.swift` is committed.

## Run

```sh
easystream serve          # est:// on 127.0.0.1:48079, HTTP (webui + /est/ws) on :48078
```
