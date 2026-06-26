# Agamotto

A macOS instant-replay recorder — runs in the background continuously buffering your
screen + audio and saves the **last N seconds/minutes on a hotkey** (an Nvidia ShadowPlay
"instant replay" for the Mac). Named after the Eye of Agamotto, which rewinds time.

**Stack:** pure native Swift — ScreenCaptureKit capture → `AVAssetWriter` rolling
fragmented-MP4 segment ring → `AVMutableComposition`/`AVAssetExportSession` for saves.
Single signed `.app`, no bundled ffmpeg. (See the design notes for why, vs. the
ffmpeg/Tauri approach.)

Locked decisions: distributable product · entire-display capture · system + mic audio ·
macOS 14+.

## Status: Phase 0 — capture spike

Proves the riskiest unknown end-to-end: **ScreenCaptureKit → AVAssetWriter → a playable
`.mp4`**, with real Screen Recording + Microphone permission checks, and surfaces the
behaviors that drive the rest of the design (idle frames on a static screen, encoder
backpressure).

### Run it

```bash
swift run AgamottoSpike
```

First run will prompt for **Screen Recording** (and **Microphone**) permission. Because
this is a CLI, macOS attributes the grant to the **host app** (Terminal/Xcode/iTerm) — grant
it there, then re-run. It captures 1080p60 for 10 seconds and writes
`~/Downloads/agamotto-spike-<timestamp>.mp4`.

> Tip: move some windows around during the 10s so you can see real motion in the clip and a
> high "video frames written" count. Leave the screen static and watch "idle frames skipped"
> climb — that's exactly why Phase 1 adds a constant-frame-rate pacer.

### What the output tells you

- **Video frames written / Effective FPS** — capture + encode is working and keeping pace.
- **Idle frames skipped** — SCK delivers nothing new on a static screen → motivates the CFR
  pacer (duplicate-last-frame) in Phase 1.
- **Audio buffers written** — system-audio capture via SCK works (no BlackHole needed).
- **File size + "pipeline validated"** — the muxed `.mp4` is real and playable.

## Layout

```
Package.swift
Sources/
  AgamottoKit/                 # reusable capture engine (grows into the app core)
    CaptureConfig.swift        # resolution/fps/bitrate presets
    Permissions.swift          # Screen Recording + Microphone TCC helpers
    ScreenCaptureRecorder.swift# SCStream -> AVAssetWriter -> .mp4
  AgamottoSpike/               # Phase 0 executable
    AgamottoSpike.swift
Distribution/                  # reference artifacts for the eventual signed app bundle
  Agamotto.entitlements        # hardened runtime + mic
  Info.plist                   # LSUIElement agent, mic usage string, min OS
```

## Roadmap

- **Phase 0** ✅ capture spike (this).
- **Phase 1** — segment ring (`AVAssetWriter` rotating fragments) + CFR pacer + hotkey save
  of the last N seconds via `AVMutableComposition` (passthrough).
- **Phase 2** — system + mic audio (mic via `AVCaptureSession`; A/V sync; mix/2-track).
- **Phase 3** — menu-bar app shell, settings, permission onboarding (deep-link + poll-to-resume).
- **Phase 4** — robustness: crash recovery, display-change restart, single-instance, adaptive quality.
- **Phase 5** — ship: Developer ID signing, notarization, Sparkle auto-update.
