#!/usr/bin/env bash
# Build the macOS easystream daemon.
#
# MUST run ON macOS. Unlike the Linux/Windows daemons (Rust, cross-compiled in a
# container), this one cannot be built in a Linux container:
#   * it links Darwin-only frameworks — ScreenCaptureKit, VideoToolbox, AppKit,
#     ApplicationServices (AXUIElement / CGEvent) — which exist only in the
#     macOS SDK, and
#   * Swift has no macOS cross-toolchain on Linux.
# So the build runs in the macOS guest/host itself (see the sandbox image's
# build flow), never from a Containerfile.
#
# The web UI is fetched from the shared repo first: Swift has no `include_str!`,
# and the daemon must stay a SINGLE boot-fetchable executable, so build-webui.sh
# also GENERATES Sources/a11y/Assets.swift (the UI inlined as string literals).
set -Eeuo pipefail
cd "$(dirname "$0")"

./build-webui.sh
swift build -c release
echo "built: .build/release/easystream"
