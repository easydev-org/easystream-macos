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

## Audio (system audio capture)

`Hello.hasAudio` is 1 when audio capture is available, and `0x05` Opus frames
carry 20 ms packets to viewers that send `0x06 AudioReq` (see `EST.md`).

The daemon encodes with AudioToolbox's built-in `kAudioFormatOpus`, so there is
still **no third-party library** — but on macOS the *capture* side needs one
extra system component, because **ScreenCaptureKit cannot be used here**:

> `SCStreamConfiguration.capturesAudio` never starts in a VM. This guest has no
> GPU driver (`No Kext Loaded`, software renderer), so `replayd`'s
> DisplayStream creation fails with `CoreGraphics error 1003 "Start stream
> failed"`, and the audio side of the stream never comes up either. The same
> limitation is why the video path uses `AVCaptureScreenInput` instead of SCK.

### How it works

The daemon uses the standard macOS "virtual audio device" technique:

1. **A BlackHole 2ch loopback device must be installed** (a *user-space* HAL
   plug-in at `/Library/Audio/Plug-Ins/HAL/BlackHole.driver`; **not** a kext, so
   no SIP/kext-consent/OpenCore changes are involved). Without it the daemon
   logs `no BlackHole device; system audio capture unavailable` and advertises
   `hasAudio = 0`.
2. **Wrap BlackHole in an aggregate device clocked by the real output device**
   (the machine's built-in/QEMU sound card). BlackHole alone has no clock source
   and stays silent — `AudioDeviceStart` on it even hangs — so the aggregate's
   `kAudioAggregateDeviceClockDeviceKey` is what makes it usable. The aggregate
   is set as the default output, so every application's audio is routed into it
   (and therefore into BlackHole).
3. **Open an AUHAL unit in duplex on the aggregate** and pull the looped-back
   PCM in the input callback. Note that for an input callback `ioData` is
   *always nil* — you must call `AudioUnitRender` into your own buffer. The PCM
   is accumulated until a full 20 ms frame (960 frames) is available, then
   handed to the Opus `AudioConverter`.

### Installing BlackHole

```sh
# The driver is a user-space HAL plug-in (no kext, no reboot of the kernel).
git clone --depth 1 https://github.com/ExistentialAudio/BlackHole.git
cd BlackHole
xcodebuild -project BlackHole.xcodeproj -scheme BlackHole -configuration Release \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build
sudo mkdir -p /Library/Audio/Plug-Ins/HAL
sudo cp -R <DerivedData>/Build/Products/Release/BlackHole.driver \
  /Library/Audio/Plug-Ins/HAL/
sudo killall coreaudiod          # coreaudiod re-scans the HAL plug-ins
```

`BlackHole.driver` then appears in `system_profiler SPAudioDataType` as
`BlackHole 2ch` and persists across reboots (it lives on the root filesystem).

### Host requirement

The guest needs an output device to act as the aggregate's clock, so the QEMU
VM must expose a sound card — i.e. the sandbox deployment sets `AUDIO=Y`
(`SOUND` defaults to `usb-audio`, which is enough; `multi=on` is not required).
**No OpenCore/EFI change is needed**: the `boot.img` is byte-identical to the
stock image.
