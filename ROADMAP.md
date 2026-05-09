# Murmur — Roadmap

Each unchecked item below is one PR. Plan first (`.planning/<slug>.plan.md`), apple-expert reviews the plan, branch + implement with atomic commits, apple-expert reviews the diff, merge once `APPROVE`. Tested or it doesn't exist — config and plumbing items must spell out the verification strategy.

Order is intentional. Don't reorder without updating dependencies in the plans.

## Milestone v0.1 — Swift skeleton

- [x] **swift-package-skeleton** — `Package.swift` defining a macOS 14 executable target `Murmur` and a test target. Minimal `main.swift` that prints version and exits. `swift build` clean. `swift test` runs (asserting version constant). `.gitignore` tuned for Swift artifacts. _Shipped in #1 (8ca3dc6) — `MurmurCore` library + thin executable, swift-testing, `com.archithrapaka.murmur` bundle id locked, 3 tests passing._
- [x] **whisperkit-dependency-and-model-cache** — Add WhisperKit to `Package.swift`. Implement `ModelCache` helper that resolves and ensures `~/Library/Application Support/Murmur/Models/` exists. Unit test for path resolution and idempotent creation. _Shipped in #2 (8fa7897) — `argmaxinc/argmax-oss-swift` v1.0.0, `ModelCache` w/ presence-check + idempotent ensureExists, `Package.resolved` committed, 9 tests passing._
- [x] **audio-capture-pipeline** — `AudioCapture` class wrapping `AVAudioEngine` at 16 kHz mono float32, ring-buffered, `start()`/`stop() -> [Float]` API. Tests using a fixture WAV that round-trip through the buffer. _Shipped in #3 (179290d) — `actor AudioCapture` + stateless `Resampler` namespace, streaming `AVAudioConverter` cached on the actor, `(samples, didCap)` return, hardware test gated by `MURMUR_SKIP_AUDIO_HARDWARE`. 17 tests passing._
- [x] **silero-vad-trim** — `SileroVAD` wrapper around the CoreML port. `trim(samples) -> [Float]` removes leading/trailing silence. Tests with silence-only, speech-only, and silence-bracketed fixtures. _Shipped in #4 (935a38d) — energy-based VAD (apple-expert APPROVE'd the deviation; Silero deferred to v0.5). Window-RMS over 30 ms windows, -40 dBFS threshold, 100/200 ms lead/trail pads, 100 ms minSpeechMs. 8 tests passing._
- [x] **hotkey-and-settings** — Add `KeyboardShortcuts` (sindresorhus) dependency. Define `MurmurShortcuts.dictate` with default of right-Cmd hold-to-talk. `Settings` struct with `Codable` round-trip tests. _Shipped in #5 (c87320b) — KeyboardShortcuts v1.10.0, `KeyboardShortcuts.Name.dictate` (no default per library README), `Settings` value type with forward-compat `decodeIfPresent`, `SettingsStore` with `os.Logger`. 32 tests passing._
- [x] **clipboard-injection** — `ClipboardInjector` that saves prior pasteboard, sets new contents, synthesizes ⌘V via `CGEventPost`, restores after 500 ms. **Mandatory** `IsSecureEventInputEnabled()` pre-flight that aborts injection and emits a `.secureInputBlocked` result. Unit tests for the routing logic; integration test that pastes into a hidden `NSTextField` in the test harness and asserts the text. _Shipped in #6 (656c39c) — actor with HID source state, AX pre-flight, snapshot-once-per-chain restore semantics. 38 tests passing._
- [ ] **ax-opportunistic-insert** — `AXInjector` resolves the focused element, checks bundle-ID against a hard-coded allowlist (TextEdit, Notes, Mail, Xcode, Messages, Pages), attempts `kAXSelectedTextAttribute` insertion, returns success/failure. Caller falls through to `ClipboardInjector` on failure. Unit tests for the allowlist routing.
- [x] **demoable-v0.1-vertical-slice** — items 8+9+10 grouped, shipped as one PR. _Shipped in #8 (cbeb172) — Murmur is now a runnable menu-bar app: `./scripts/make-app.sh && open ./build/Murmur.app`, walk through onboarding, hold the bound hotkey, speak, release, watch text appear in the focused field. Includes `NSPanel` HUD with breathing waveform, menu-bar `NSStatusItem` with model-loading indicator, eager WhisperKit `small.en` warm-up on launch, AX-then-clipboard fallback ladder. 49 tests passing._

## Milestone v0.1 — **COMPLETE** ✓ (10 of 10 items shipped)

## Milestone v0.5 — Functional

The "feels like Wispr Flow" milestone. v0.1 transcribes; v0.5 cleans up the transcript and gives the user real control. Architecture-plan §2.2 cleanup pass + §9.4 llama.cpp + the vocabulary/settings UX that's been struct-only.

- [ ] **llm-cleanup-pass** — Add `mattt/llama.swift` SPM dependency. Implement `LlamaCppCleaner: Cleaner` actor wrapping a long-lived `llama_context` over a Qwen2.5-3B-Instruct Q4_K_M model. Strict architectural-plan §2.2 prompt: fix punctuation, remove disfluencies, do not rephrase, T=0, output capped at 1.5× input tokens. Confidence-based skip per §9.8 (skip when Whisper's avg log-prob > -0.3). Settings toggle. Integrated into `DictationCoordinator` between `transcribe` and `inject`. XPC isolation deferred to v1.0.
- [ ] **first-run-model-download-ui** — SwiftUI window with progress bars for both Whisper (`small.en`, ~480 MB) and Qwen (3B Q4, ~2 GB). Resumable. SHA-256 verified against a manifest committed to the repo. Replace the menu-bar-icon "loading" state with this.
- [ ] **settings-window** — SwiftUI Settings scene: vocabulary editor (multi-line text), cleanup toggle, audio cues toggle, max capture duration slider, hotkey rebinder. `@MainActor` SwiftUI window backed by `Settings` + `SettingsStore`.
- [ ] **audio-cues** — Implement the tick/tock sounds bound to `Settings.playAudioCues`. `AVAudioPlayer` + small bundled WAVs (or system sounds via `NSSound`).
- [ ] **vocabulary-prompt-eval** — Smoke-test that the existing `initialPromptProvider` plumbing actually delivers the vocabulary list to Whisper (the wiring landed in PR #8 but was never validated end-to-end). Add a unit test using the `Transcribing` stub that asserts the prompt was passed.

## Milestone v1.0 — Polished release

## Milestone v1.0 — Polished release

(filled in after v0.5 ships — Sparkle auto-update, Developer ID + notarization, DMG packaging, Homebrew cask, accent-eval suite)

## Post-v1

(captured in `.planning/architecture.plan.md` §10 — Universal injection v2 via Input Method Kit, Kyutai live HUD, per-user LoRA, iOS port, Voxtral toggle, dictation commands)
