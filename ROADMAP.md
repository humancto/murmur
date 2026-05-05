# Murmur — Roadmap

Each unchecked item below is one PR. Plan first (`.planning/<slug>.plan.md`), apple-expert reviews the plan, branch + implement with atomic commits, apple-expert reviews the diff, merge once `APPROVE`. Tested or it doesn't exist — config and plumbing items must spell out the verification strategy.

Order is intentional. Don't reorder without updating dependencies in the plans.

## Milestone v0.1 — Swift skeleton

- [x] **swift-package-skeleton** — `Package.swift` defining a macOS 14 executable target `Murmur` and a test target. Minimal `main.swift` that prints version and exits. `swift build` clean. `swift test` runs (asserting version constant). `.gitignore` tuned for Swift artifacts. _Shipped in #1 (8ca3dc6) — `MurmurCore` library + thin executable, swift-testing, `com.archithrapaka.murmur` bundle id locked, 3 tests passing._
- [ ] **whisperkit-dependency-and-model-cache** — Add WhisperKit to `Package.swift`. Implement `ModelCache` helper that resolves and ensures `~/Library/Application Support/Murmur/Models/` exists. Unit test for path resolution and idempotent creation.
- [ ] **audio-capture-pipeline** — `AudioCapture` class wrapping `AVAudioEngine` at 16 kHz mono float32, ring-buffered, `start()`/`stop() -> [Float]` API. Tests using a fixture WAV that round-trip through the buffer.
- [ ] **silero-vad-trim** — `SileroVAD` wrapper around the CoreML port. `trim(samples) -> [Float]` removes leading/trailing silence. Tests with silence-only, speech-only, and silence-bracketed fixtures.
- [ ] **hotkey-and-settings** — Add `KeyboardShortcuts` (sindresorhus) dependency. Define `MurmurShortcuts.dictate` with default of right-Cmd hold-to-talk. `Settings` struct with `Codable` round-trip tests.
- [ ] **clipboard-injection** — `ClipboardInjector` that saves prior pasteboard, sets new contents, synthesizes ⌘V via `CGEventPost`, restores after 500 ms. **Mandatory** `IsSecureEventInputEnabled()` pre-flight that aborts injection and emits a `.secureInputBlocked` result. Unit tests for the routing logic; integration test that pastes into a hidden `NSTextField` in the test harness and asserts the text.
- [ ] **ax-opportunistic-insert** — `AXInjector` resolves the focused element, checks bundle-ID against a hard-coded allowlist (TextEdit, Notes, Mail, Xcode, Messages, Pages), attempts `kAXSelectedTextAttribute` insertion, returns success/failure. Caller falls through to `ClipboardInjector` on failure. Unit tests for the allowlist routing.
- [ ] **floating-hud-scaffold** — `NSPanel` at `.floating` level, click-through, `NSVisualEffectView` `.hudWindow` material, breathing-waveform SwiftUI view bound to a `@Published` amplitude. Reduced-motion respected. Snapshot tests of the SwiftUI view in `recording`, `idle`, `processing` states.
- [ ] **menu-bar-mic-indicator** — `NSStatusItem` with a state-driven icon: idle (mic outline), recording (filled mic + red dot). Bound to `AudioCapture.isCapturing`. Snapshot tests of both icon states.
- [ ] **end-to-end-v0.1** — Wire it together. Hotkey-down opens mic + shows HUD; hotkey-up runs VAD trim → WhisperKit transcribe → ClipboardInjector or AXInjector. Manual verification checklist in the PR; automated test that runs the full pipeline against a fixture WAV and asserts the injected text matches expected within an edit distance of 2.

## Milestone v0.5 — Functional

(filled in after v0.1 ships)

## Milestone v1.0 — Polished release

(filled in after v0.5 ships)

## Post-v1

(captured in `.planning/architecture.plan.md` §10 — Universal injection v2 via Input Method Kit, Kyutai live HUD, per-user LoRA, iOS port, Voxtral toggle, dictation commands)
