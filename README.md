# Agamotto

A macOS instant-replay recorder — runs in the background continuously buffering your
screen + audio and saves the **last N seconds/minutes on a hotkey** (an Nvidia ShadowPlay
"instant replay" for the Mac). Named after the Eye of Agamotto, which rewinds time.

**Stack:** pure native Swift — ScreenCaptureKit capture → `AVAssetWriter` rolling MP4
segment ring → `AVMutableComposition`/`AVAssetExportSession` for saves. Single signed
`.app`, no bundled ffmpeg. The reusable engine lives in the **`AgamottoKit`** local Swift
package; the menu-bar app is an Xcode target that depends on it.

Locked decisions: distributable product · entire-display capture · system + mic audio ·
macOS 14+.

## Status

A working menu-bar app: always-armed background capture, save-last-N-seconds on a global
hotkey, **Smart Pause** so DRM/streaming apps still play, a settings window, and
launch-at-login. (The Phase 0–2 engine CLIs are still available — see below.)

## Install & run (no Apple Developer account needed)

```bash
Distribution/install-local.sh
```

Builds a Release copy, installs it to `/Applications/Agamotto.app`, and launches it (look
for the rewind icon in the menu bar). Re-run anytime to update.

This needs **no** Apple Developer Program membership: notarization / Developer ID only
matter for apps that travel to *other* Macs (Gatekeeper checks a download "quarantine"
flag). An app you build and copy locally is never quarantined, so it just runs — signed
with the free Apple Development certificate Xcode sets up. On first launch, grant **Screen
Recording** and **Microphone** when prompted (or in System Settings → Privacy & Security).

## Using it

- **Save the last N seconds** — `⌃⌥R` (rebindable). The clip lands in `~/Movies/Agamotto`.
- **Pause / resume capture** — `⌃⌥P`, or the menu. See Smart Pause below.
- **Menu bar** — status, Save Replay, Pause/Resume, reveal/open clips, Settings, About.
- **Settings** — resolution & frame rate, replay & buffer length, microphone + gain, output
  folder, protected-app list, shortcuts, and **Launch at login**.

### Smart Pause (so you can watch Netflix, Apple TV, Disney+…)

macOS blanks DRM-protected video on screen whenever *any* screen capture is active (it's an
OS-level anti-piracy guarantee — even Apple's own screen recorder does it). So an always-on
recorder would make streaming apps unwatchable. Agamotto handles it:

- **Automatically** — capture pauses (fully tearing down the session, clearing the recording
  indicator) while a protected app is frontmost, and resumes when you leave. The app list is
  editable in Settings → Protected playback.
- **Manually** — `⌃⌥P` toggles capture. Use it before **in-browser** streaming, which can't
  be auto-detected.

You lose nothing: DRM content can't be captured anyway, so a buffer during playback is
useless. (On Windows, ShadowPlay can stay always-on because Windows blanks the *recording*,
not the live screen — macOS is stricter.)

## Engine demos (CLI)

```bash
swift run --package-path AgamottoKit AgamottoReplay   # ring 20s, save last 10s
swift run --package-path AgamottoKit AgamottoSpike     # minimal Phase-0 capture spike
```

`AgamottoReplay` records 1080p60 + system audio + mic into a rolling buffer, then saves the
last 10s to `~/Downloads/agamotto-replay-<ts>.mp4`. Run as a CLI, macOS attributes the
permission grant to the host (Terminal/Xcode) — grant it there and re-run.

## How it works

- **Video** — ScreenCaptureKit → a constant-frame-rate pacer (re-emits/duplicates the
  latest frame so output stays steady on a static screen) → rolling ~1s H.264 MP4 segments
  on disk (each starts on a keyframe → keyframe-aligned ring), pruned by count.
- **Audio** — system (SCK) and mic (`AVCaptureSession`) are captured into in-memory PCM
  ring buffers, each sample tagged with its host-clock time.
- **Save** — select the trailing video segments for the window, extract both audio rings
  over the exact same host-time window, mix offline, encode once to AAC, and mux with the
  passthrough video (separate video/audio composition tracks) into the final MP4.
- **Smart Pause** — the app tears the capture session down while protected apps are active
  and rebuilds it after, so DRM playback and recovery/restart logic never fight each other.

## Layout

```
AgamottoKit/                       # local Swift package — the reusable capture engine
  Package.swift
  Sources/
    AgamottoKit/                   # CaptureConfig, SegmentRecorder, audio rings, muxer, …
    AgamottoSpike/                 # Phase 0 demo
    AgamottoReplay/                # Phase 1/2 demo (ring + save last N seconds)
Agamotto/
  Agamotto.xcodeproj               # macOS menu-bar app — depends on AgamottoKit
  Agamotto/                        # app target sources (ReplayController, MenuContent, …)
Distribution/
  install-local.sh                 # build + install to /Applications (local use)
  notarize.sh                      # Developer ID archive → notarize → staple (distribution)
  ExportOptions.plist              # Developer ID export options
```

## Building a signed release (for distributing to other Macs)

Requires a paid Apple Developer Program membership + a **Developer ID Application**
certificate. Then:

```bash
Distribution/notarize.sh
```

Archives, exports with Developer ID signing, notarizes (`notarytool submit --wait`),
staples, and verifies — output in `build/`. The script's header documents the one-time
credential setup; it fails fast if the certificate isn't installed.

## Roadmap

- **Phase 0** ✅ capture spike (SCK → AVAssetWriter → .mp4).
- **Phase 1** ✅ segment ring + CFR pacer + save last N seconds.
- **Phase 2** ✅ system + mic audio, host-time-aligned, mixed at save.
- **Phase 3** ✅ menu-bar app (`LSUIElement` agent, global hotkey, settings, saves to `~/Movies/Agamotto`).
- **Phase 4** ✅ robustness: capture-failure recovery, display-change restart, single-instance, rebindable hotkey.
- **Smart Pause** ✅ auto/manual pause so DRM/streaming apps stay watchable.
- **Launch at login** ✅ via `SMAppService`.
- **Phase 5** — ship: Hardened Runtime + entitlements ✅; Developer ID signing + notarization (scripted, ✅ ready); Sparkle auto-update (pending).
