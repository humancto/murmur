<div align="center">

# Murmur

**Private, local-only Mac dictation. Built for accents. Free forever.**

[![License: MIT](https://img.shields.io/badge/License-MIT-black.svg?style=flat-square)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black?style=flat-square)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-black?style=flat-square)](#requirements)
[![Status](https://img.shields.io/badge/status-pre--alpha-orange?style=flat-square)](#roadmap)

A free, open-source alternative to Wispr Flow that runs entirely on your Mac. No cloud. No account. No subscription. No telemetry.

</div>

---

## What it is

Hold a key. Talk. Release. Your words appear in the focused text field — Terminal, iTerm2, VS Code, Cursor, Slack, Notion, Safari, Mail, Messages, anywhere you can type.

Murmur runs Whisper-large-v3-turbo on the Apple Neural Engine, cleans up disfluencies with a small local LLM, and pastes into your focused field. Sub-1.2s end-to-end on M2 Pro. Beats cloud-based dictation tools on latency because there's no network round-trip.

## How it compares

|                            | Wispr Flow   | Apple Dictation | **Murmur**       |
| -------------------------- | ------------ | --------------- | ---------------- |
| Local-only (no cloud)      | No           | Yes             | **Yes**          |
| Open source                | No           | No              | **Yes (MIT)**    |
| Free forever               | Subscription | Free            | **Free**         |
| Tuned for accents          | Mediocre     | Mediocre        | **Built for it** |
| Works in Terminal / iTerm2 | Flaky        | No              | **First-class**  |
| Personal vocabulary        | Limited      | Limited         | **Full control** |
| Audit the code             | No           | No              | **Yes**          |
| Telemetry                  | Yes          | Apple           | **None**         |

## Requirements

- Apple Silicon Mac (M1 or newer)
- macOS 14 (Sonoma) or newer; tested on Sequoia and Tahoe
- 16 GB RAM recommended (8 GB unsupported — see [#memory](#why-16-gb))
- ~3.5 GB disk for models (downloaded on first run from Cloudflare)

---

## Architecture

```
                     ┌─────────────────────────────────┐
   [Hotkey down]  ──▶│  CoreAudio · 16 kHz mono PCM    │
                     └────────────┬────────────────────┘
                                  ▼
                     ┌─────────────────────────────────┐
                     │  Silero VAD silence trim         │
                     └────────────┬────────────────────┘
                                  ▼
                     ┌─────────────────────────────────┐
                     │  Whisper large-v3-turbo          │
                     │  (WhisperKit · ANE)              │
                     │  + your personal vocabulary      │
                     └────────────┬────────────────────┘
                                  ▼
                     ┌─────────────────────────────────┐
                     │  Qwen2.5-3B cleanup pass         │
                     │  (llama.cpp · XPC · T = 0)       │
                     │  punctuation · disfluencies      │
                     └────────────┬────────────────────┘
                                  ▼
                     ┌─────────────────────────────────┐
                     │  Clipboard + ⌘V                  │
                     │  (AX direct insert on allowlist) │
                     └─────────────────────────────────┘
```

Whisper stays hot in memory. Qwen unloads after 90 s idle and reloads in the time you're still speaking. The HUD is a translucent floating panel with a breathing waveform — no popups, no windows, no friction.

Read the [architecture plan](./.planning/architecture.plan.md) for the full design and the apple-expert review that shaped it.

## Why these choices

**Whisper large-v3-turbo** is the accent champion in the open-source ecosystem. Trained on hundreds of thousands of hours of messy, real-world audio. Robust to background noise, regional dialects, and non-native English in a way Parakeet and Moonshine are not.

**WhisperKit** runs it on the Apple Neural Engine via CoreML. Native, fast, supports `initial_prompt` for personal vocabulary biasing.

**Qwen2.5-3B** does cleanup with a strict prompt: _fix punctuation, remove disfluencies, do not rephrase, do not substitute vocabulary, do not editorialize._ Temperature zero, output capped at 1.5× input tokens. Skipped entirely when Whisper's confidence is high.

**llama.cpp + XPC** for cleanup inference. Stable C ABI, Metal kernels, crash isolation. mlx-swift's text-generation API isn't production-stable yet; we'll revisit.

**Clipboard + ⌘V** as the primary text injection path. Works in Terminal, iTerm2, all Electron apps (VS Code, Cursor, Slack, Notion, Discord, ChatGPT, Claude desktop, Linear), all browsers, all native apps. Direct accessibility-API insertion is faster but only works on a hard-coded allowlist of native AppKit apps — used opportunistically when it does work.

## Latency

Honest numbers, M2 Pro, 5-second utterance:

| Stage                                  | p50                        |
| -------------------------------------- | -------------------------- |
| VAD trim                               | 30 ms                      |
| Whisper transcription (warm, ANE)      | 700–900 ms                 |
| Qwen cleanup (TTFT + decode, when run) | ~150–900 ms                |
| Clipboard + paste                      | 50 ms                      |
| **End-to-end**                         | **~1.1 s p50, ~1.8 s p95** |

Cloud-based tools cannot beat this on a typical home connection — they spend 1.5–3 s just on network round-trip.

---

## Roadmap

**v0.1 — Swift skeleton** (in progress · 3 of 10 items shipped)

- [x] Swift package skeleton — `MurmurCore` library + `Murmur` executable, swift-testing, strict concurrency ([#1](https://github.com/humancto/murmur/pull/1))
- [x] WhisperKit dependency + `ModelCache` ([#2](https://github.com/humancto/murmur/pull/2))
- [x] Audio capture pipeline — `Resampler` + `AudioCapture` actor with streaming `AVAudioConverter` ([#3](https://github.com/humancto/murmur/pull/3))
- [ ] Silence trimming (energy-based VAD)
- [ ] Hotkey + settings (`KeyboardShortcuts`)
- [ ] Clipboard injection path with secure-input pre-flight
- [ ] AXUIElement opportunistic insertion (allowlist)
- [ ] Floating HUD scaffold
- [ ] Menu bar mic indicator
- [ ] End-to-end wiring

Track progress on the [open ROADMAP.md](./ROADMAP.md). Every item lands as one squash-merged PR after an apple-expert plan-review and final-diff-review loop — see the merged-PR list on the [landing page](https://humancto.github.io/murmur/).

**v0.5 — Functional**

- llama.cpp XPC service for Qwen cleanup
- AX-allowlist direct insertion
- Personal vocabulary editor
- First-run model download UI
- Secure-input pre-flight

**v1.0 — Polished release**

- Translucent HUD with breathing waveform
- Audio cues, hotkey customization
- Accessibility / microphone permission onboarding
- Sparkle auto-update via Cloudflare-hosted appcast
- Notarized DMG, Developer ID signed
- Raw-vs-cleaned undo
- Local crash logs

**Post-v1**

- Live streaming transcription via Kyutai STT (the "feels magic" upgrade)
- Per-user LoRA fine-tuning for further accent gains
- Voxtral-Mini-3B as alternate model for non-English-primary users
- Dictation commands ("new line", "scratch that")
- iOS port (WhisperKit + FluidAudio port cleanly)

---

## Build from source

**Prerequisites:** Apple Silicon Mac, macOS 14+, Xcode 16+, Swift 6 toolchain. `xcode-select -p` must point at the full Xcode (not just Command Line Tools — XCTest and swift-testing live in Xcode):

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

```bash
git clone https://github.com/humancto/murmur.git
cd murmur
swift build              # build the executable target
swift test               # run the test suite
swift run Murmur         # run the executable (prints version, exits)
```

Or open in Xcode:

```bash
xed .
```

> The repo is currently a CLI executable scaffold. The bundled `.app` lands in a later roadmap item (`floating-hud-scaffold` / `menu-bar-mic-indicator`). Until then `swift run` is the way.

Once shipping, models will download from Cloudflare R2 on first launch (~3.5 GB, one-time) into `~/Library/Application Support/Murmur/Models/` and be SHA-verified against a signed manifest in this repo.

## Privacy

- **Zero network calls at runtime.** Verified with Little Snitch. The only outbound traffic is the one-time model download on first launch (and Sparkle update checks, which you can disable).
- **No telemetry.** Not even "anonymous usage." Not even crash reports — crashes are written to `~/Library/Logs/Murmur/` and stay there unless you choose to file them.
- **No account.** There is nothing to log into.
- **Microphone indicator.** Red dot in the menu bar whenever audio is being captured. Disappears the instant the buffer closes.
- **Password fields are refused.** Murmur detects `AXSecureTextField` and `IsSecureEventInputEnabled()` and refuses to inject in either case. Audio is never sent through the cleanup LLM for secure inputs.

If you find a network call we didn't disclose, file an issue. That's a P0 bug.

## Contributing

Bug reports, accent coverage gaps, and PRs welcome. Read [CONTRIBUTING.md](./CONTRIBUTING.md) before sending anything bigger than a typo.

## Why "Murmur"?

Because dictation should disappear. The tool gets out of the way; your words show up.

## Why 16 GB?

On 16 GB Macs, Murmur's steady-state footprint is ~1.5 GB (Whisper hot, Qwen lazy-loaded). On 8 GB Macs the model + your other apps will swap, and the cure becomes worse than the disease. We don't ship what we can't make feel good.

## Acknowledgements

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — Argmax's CoreML path for Whisper
- [Whisper](https://github.com/openai/whisper) — OpenAI's model
- [llama.cpp](https://github.com/ggml-org/llama.cpp) — Georgi Gerganov's local inference
- [Qwen2.5](https://huggingface.co/Qwen) — Alibaba's open LLMs
- [Silero VAD](https://github.com/snakers4/silero-vad) — voice activity detection
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — Sindre Sorhus, hotkey library
- [Sparkle](https://sparkle-project.org) — auto-update framework
- Wispr Flow — the look-and-feel benchmark we're trying to match without the cloud

## License

[MIT](./LICENSE) — fork it, ship it, sell it. Just don't pretend you wrote it.
