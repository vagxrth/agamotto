# Agamotto

A macOS instant-replay recorder — runs in the background continuously buffering your
screen + audio and saves the **last N seconds/minutes on a hotkey** (an Nvidia ShadowPlay
"instant replay" for the Mac). Named after the Eye of Agamotto, which rewinds time.

**Stack:** pure native Swift — ScreenCaptureKit capture → `AVAssetWriter` rolling MP4
segment ring → `AVMutableComposition`/`AVAssetExportSession` for saves. Single signed
`.app`, no bundled ffmpeg. The reusable engine lives in the **`AgamottoKit`** local Swift
package; the menu-bar app (Phase 3) is an Xcode target that depends on it.

Locked decisions: distributable product · entire-display capture · system + mic audio ·
macOS 14+.

## Status: Phases 0–2 complete (capture engine + audio)

The engine continuously rings video to disk and audio to memory, and saves the last N
seconds as a clip with synced, mixed system + mic audio.

### Run the replay demo

```bash
swift run --package-path AgamottoKit AgamottoReplay
```

Records 1080p60 + system audio + mic into a rolling buffer for 20s, then saves the last
10s to `~/Downloads/agamotto-replay-<ts>.mp4`. (Also:
`swift run --package-path AgamottoKit AgamottoSpike` for the minimal Phase-0 capture spike.)

First run prompts for Screen Recording + Microphone; run as a CLI, macOS attributes the
grant to the host app (Terminal/Xcode) — grant it there and re-run.

## How it works

- **Video** — ScreenCaptureKit → a constant-frame-rate pacer (re-emits/duplicates the
  latest frame so output stays steady on a static screen) → rolling ~1s H.264 MP4 segments
  on disk (each starts on a keyframe → keyframe-aligned ring), pruned by count.
- **Audio** — system (SCK) and mic (`AVCaptureSession`) are captured into in-memory PCM
  ring buffers, each sample tagged with its host-clock time.
- **Save** — select the trailing video segments for the window, extract both audio rings
  over the exact same host-time window, mix offline, encode once to AAC, and mux with the
  passthrough video (separate video/audio composition tracks) into the final MP4.

## Layout

```
AgamottoKit/                       # local Swift package — the reusable capture engine
  Package.swift
  Sources/
    AgamottoKit/                   # CaptureConfig, SegmentRecorder, audio rings, muxer, …
    AgamottoSpike/                 # Phase 0 demo
    AgamottoReplay/                # Phase 1/2 demo (ring + save last N seconds)
Agamotto.xcodeproj                 # macOS menu-bar app (Phase 3+) — depends on AgamottoKit
Agamotto/                          # app target sources
Distribution/                      # reference entitlements + Info.plist for the signed app
```

## Roadmap

- **Phase 0** ✅ capture spike (SCK → AVAssetWriter → .mp4).
- **Phase 1** ✅ segment ring + CFR pacer + save last N seconds.
- **Phase 2** ✅ system + mic audio, host-time-aligned, mixed at save.
- **Phase 3** — menu-bar app shell (`LSUIElement` agent, `NSStatusItem`, global hotkey, settings).
- **Phase 4** — robustness: crash recovery, display-change restart, single-instance, adaptive quality.
- **Phase 5** — ship: Developer ID signing, notarization, Sparkle auto-update.
```
