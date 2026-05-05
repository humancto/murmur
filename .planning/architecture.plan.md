# Murmur — Architecture & v1 Plan

**One-line:** Local, private, beautiful Mac dictation. Open source. Beats Wispr Flow on accents because it's built around them.

**Constraints:**

- 100% on-device. No network calls. Ever.
- Apple Silicon only (M1+). Universal binary not in scope.
- Free, MIT-licensed, GitHub from day one.
- Premium feel, not "good enough." If it feels cheap, it's wrong.
- Accent-first English (incl. Indian English, since author's audio is the test set).
- **Universal text injection** — works anywhere a Mac has a focused text field: Terminal, iTerm2, VS Code, Cursor, Slack, Notion, Safari/Chrome, Mail, Messages, ChatGPT/Claude desktop. If the OS lets you type there, Murmur dictates there.
- **Inspired by Wispr Flow's look & feel** — premium translucent surfaces, butter-smooth motion, breathing waveform, tasteful glassmorphism. Murmur should feel like it ships with macOS, not bolted on.

---

## 0. Wispr Flow inspiration — what we steal, what we improve

**Steal (look & feel):**

- Translucent floating "pill" HUD that hovers near the caret while recording, fades elegantly on stop. `NSPanel` + `NSVisualEffectView` (`.hudWindow` material).
- Breathing/pulsing waveform during capture, not a static bar — responsive to live RMS amplitude. Spring-damped animation, not linear.
- Subtle micro-interactions: HUD scale-in 0.95→1.0 on activate, 200ms ease-out; fade-out 150ms on dismiss; haptic-feel timing (no actual haptics on Mac).
- Single-key push-to-talk feel: zero modal UI, zero windows-popping-up. The HUD _is_ the entire UX surface.
- "Cleaned, not rewritten" copy — punctuation/disfluencies fixed, voice preserved.
- Quiet onboarding: one-time accessibility/mic permission, then disappears.

**Improve over Wispr Flow:**

- 100% local — no cloud roundtrip, no account, no telemetry, no subscription.
- Accent-first — built and benchmarked on Indian English, not retrofitted.
- Open source — fork, audit, modify. MIT.
- Vocabulary editor — user-controlled `initial_prompt` for personal jargon, names, technical terms.
- Universal injection — Terminal/iTerm2 first-class (Wispr's Terminal support is flaky).

**Explicitly do NOT copy:**

- ❌ Cloud dependency.
- ❌ Account/login.
- ❌ Subscription pricing or any pricing.
- ❌ Telemetry, even "anonymous."
- ❌ Auto-launch agent that runs whether you want it or not — opt-in only.

---

## 0.5. Universal text injection — coverage matrix

Every Mac text input is reached via one of three paths. Murmur must handle all three with graceful fallback.

| Path                            | When it works                                             | Mechanism                                                                                 | Example apps                                                   |
| ------------------------------- | --------------------------------------------------------- | ----------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| **AXUIElement direct insert**   | App exposes accessibility API for focused text element    | `AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute, text)`                   | Most native AppKit apps, TextEdit, Notes, Mail                 |
| **Clipboard + simulated Cmd+V** | App accepts paste                                         | Save clipboard → set new clipboard → `CGEventPost` Cmd+V → restore clipboard ~200ms later | VS Code, Cursor, Chrome, Slack, Notion, ChatGPT/Claude desktop |
| **Direct keystroke synthesis**  | App rejects paste (rare — password fields, secure inputs) | `CGEventCreateKeyboardEvent` per character                                                | Some Electron secure inputs                                    |

**Default order:** AXUIElement → clipboard+paste → keystroke synthesis. Detect failure at each layer, fall through silently.

**Terminal-specific care:**

- **Terminal.app**: AXUIElement works for current line.
- **iTerm2**: clipboard-paste preferred (AX is partial). iTerm2 has its own "paste defensively" prompt for multi-line — handle by stripping trailing newlines from cleaned text unless user dictated "newline."
- **tmux/ssh sessions inside terminals**: clipboard-paste still works because it's keystroke-level. No special handling.
- **Vim/nvim insert mode**: clipboard-paste works as-is. (Normal mode would paste over commands — out of scope, user should be in insert mode.)

**Edge cases handled:**

- Password fields (`AXSecureTextField`) — refuse to inject, beep, show HUD warning. We never put passwords through an LLM cleanup pass.
- No focused element — capture text, copy to clipboard, show HUD "Copied to clipboard" for 2s.
- Sandboxed Mac App Store apps that block AX — fall through to clipboard-paste.

---

## 1. Architecture — two-track streaming-then-finalize

```
                    ┌─────────────────────────────────┐
   [Hotkey down] ──▶│  CoreAudio 16kHz mono PCM ring  │
                    └────────────┬────────────────────┘
                                 │
              ┌──────────────────┴──────────────────┐
              │                                     │
              ▼                                     ▼
   ┌─────────────────────┐             ┌─────────────────────────┐
   │ Track 1: live HUD   │             │ Track 2: final paste    │
   │ Kyutai STT 1B (MLX) │             │ buffer accumulates...   │
   │ 500ms streaming     │             │                         │
   │ → floating bubble   │             │ on hotkey-up:           │
   │   near cursor       │             │  Silero VAD trim ──▶    │
   │   (NOT pasted)      │             │  Whisper-large-v3-turbo │
   └─────────────────────┘             │  (WhisperKit / ANE)     │
                                       │   ↓                     │
                                       │  Qwen2.5-3B mlx-lm      │
                                       │  cleanup pass (T=0)     │
                                       │   ↓                     │
                                       │  AXUIElement paste      │
                                       │  → focused text field   │
                                       │  HUD dismisses          │
                                       └─────────────────────────┘
```

**Two tracks, one model each, no merge logic.** The live HUD is visual sugar (visible during dictation only). The pasted text is _always_ Whisper-turbo's output. This kills the "watching text rewrite itself" jank that ruins streaming-paste UX in lesser tools.

Track 1 is **optional for v1** (defer to v1.1 if it adds risk). Track 2 alone produces a working, premium tool.

---

## 2. The four axes — decisions

### 2.1 Latency — target <800ms hotkey-up to paste

Budget for a 5-second utterance:

| Stage                                                   | Budget     |
| ------------------------------------------------------- | ---------- |
| VAD silence trim                                        | 20ms       |
| Whisper-large-v3-turbo on ANE (5s audio @ 10× realtime) | ~500ms     |
| Qwen2.5-3B cleanup pass (T=0, ~50 output tokens)        | ~150ms     |
| AXUIElement paste                                       | ~30ms      |
| **Total**                                               | **~700ms** |

Perceived latency is much lower because the live HUD (Track 1) shows tokens at +500ms during recording. By hotkey-up the user has already seen ~95% of the text — paste is confirmation.

**Single biggest latency lever: keep models hot in RAM at all times.** Cold-start is jank. Memory budget ~5GB unified:

- Whisper-turbo Q4 (~1.5GB)
- Kyutai STT 1B Q4 (~1.2GB) [Track 1, optional]
- Qwen2.5-3B Q4 (~2GB)

Non-negotiable for premium feel.

### 2.2 Correctness — Whisper-turbo + paranoid cleanup

- **Source of truth:** Whisper-large-v3-turbo via WhisperKit. Best accent robustness in the open ecosystem.
- **Hallucination prevention:**
  - Silero VAD pre-trim (Whisper's #1 failure mode is "Thanks for watching!" on silence)
  - `condition_on_previous_text=False`
  - `temperature=0` with fallback only on log-prob threshold
  - User-defined `initial_prompt` (vocabulary list) — bigger accuracy gain than any model swap
- **LLM cleanup prompt** (load-bearing, do not edit casually):
  ```
  Fix punctuation, capitalization, and remove obvious disfluencies
  (um, uh, like-as-filler, repeated words). DO NOT rephrase.
  DO NOT substitute vocabulary. DO NOT add or remove information.
  Preserve technical terms exactly. Output only the cleaned text.
  ```
  T=0, top_p=1, output capped at 1.5× input tokens. Failure mode is the LLM editorializing — prompt + cap stops most of it.
- **Skip cleanup for short utterances (<6 words)** — risk/reward bad, latency matters more.

### 2.3 Premium feel — binary checklist

Every item is binary: there or it feels cheap.

- [ ] Floating HUD overlay (`NSPanel`, `.floating` level, click-through). Live waveform, live partial text, fade-in <100ms. Position: 80px above caret if discoverable, screen-center otherwise.
- [ ] Models always hot. App launches → models loaded → never unloaded. Mic does NOT open until hotkey.
- [ ] Mic privacy: red dot in menu bar while recording, gone the instant audio buffer closes. Hard requirement.
- [ ] Hotkey: default right-Cmd hold-to-talk. Configurable. Toggle mode optional but not default.
- [ ] Subtle audio cues (off by default, available): 8kHz tick on start, lower tock on stop.
- [ ] Paste path: AXUIElement `kAXSelectedTextAttribute` insertion (preserves cursor, no clipboard pollution). Fallback to clipboard+Cmd+V only if accessibility insertion fails. Restore previous clipboard contents.
- [ ] Personal vocabulary editor in settings. Plain-text list, joined and used as Whisper's `initial_prompt`.
- [ ] No first-run friction: ship CoreML model files in the app bundle, no download on first launch.
- [ ] No telemetry, ever. Local-only. Loud in marketing.

### 2.4 Accents — model + prompt + future LoRA

- **Default model: Whisper-large-v3-turbo.** This is the call.
- **Voxtral-Mini-3B as a v2 toggle** for non-English-primary users.
- **The accent unlock isn't model swap, it's `initial_prompt`.** User's name + 20 jargon terms moves accented WER more than any model upgrade in this size class.
- **Future: per-user LoRA.** WhisperKit supports adapter loading. After ~5–10h of personal audio, fine-tune drops accented WER 30–50%. Design data path day one even if we don't ship it.

---

## 3. Tech stack

| Layer        | Choice                                                                                       | Why                                                                |
| ------------ | -------------------------------------------------------------------------------------------- | ------------------------------------------------------------------ |
| Language     | **Swift 6**                                                                                  | Only path to premium HUD + AXUIElement + bundle WhisperKit cleanly |
| App shell    | SwiftUI + AppKit (`NSPanel` for HUD, `NSStatusItem` for menu bar)                            | Native, no Electron                                                |
| ASR          | **WhisperKit** (Argmax)                                                                      | CoreML/ANE, mature, supports `initial_prompt`                      |
| LLM cleanup  | **mlx-lm** Swift (via Python bridge for v0.1, native Swift port for v1) OR llama.cpp sidecar | Decision deferred to prototype                                     |
| VAD          | Silero VAD (CoreML port)                                                                     | Industry standard, tiny                                            |
| Hotkey       | `HotKey` (sindresorhus)                                                                      | Battle-tested                                                      |
| Audio        | AVAudioEngine                                                                                | Native, low-latency                                                |
| Build        | SPM-first, no CocoaPods                                                                      | landit-style                                                       |
| Distribution | DMG + Sparkle, notarized, non-sandboxed (needed for AXUIElement)                             | landit-style                                                       |
| Repo         | GitHub public, MIT                                                                           | Day-one OSS                                                        |

---

## 4. Build plan — three weekends to v1

### Weekend 1 — validate on author's voice (Python prototype)

- `mlx-whisper` push-to-talk script with `pynput` + `pyperclip`
- Instrumented end-to-end latency log
- Eval: 50 personal utterances, accented English mix
- Decision: Whisper-turbo vs Voxtral-Mini-3B as default
- **Deliverable:** `prototype/dictate.py`, `prototype/EVAL.md`

### Weekend 2 — Swift app skeleton

- Fork **Pindrop** as starting point (smallest Swift+WhisperKit codebase) OR cold-start
- Strip Pindrop's UI, replace with floating HUD
- Wire AXUIElement paste with clipboard fallback
- Hotkey + menu bar + recording indicator
- Cleanup pass (mlx-lm Python sidecar OK for v0.1)
- **Deliverable:** Functional but ugly end-to-end loop

### Weekend 3 — polish to "premium"

- HUD waveform animation (live FFT)
- Vocabulary editor in settings
- Hotkey customization
- Audio cues
- Accessibility-permission onboarding flow
- Bundled-model first-run (no download)
- Sparkle update channel set up
- Notarization + DMG packaging
- **Deliverable:** v1 release, GitHub public, signed/notarized DMG

### Post-v1 (not in scope, designed for)

- Track 1 live HUD via Kyutai STT 1B
- Per-user LoRA pipeline
- iOS port (WhisperKit + FluidAudio port cleanly)
- Voxtral-Mini-3B model toggle for non-English-primary users
- Context-aware cleanup (Slack vs code editor)

---

## 5. Cuts — explicit no's

- ❌ Parakeet/Moonshine. Faster, worse accents. Merge logic adds jank. Not worth it for accent-first product.
- ❌ Phi-4-multimodal / Qwen2-Audio / Granite. Wrong shape for low-latency dictation.
- ❌ Custom hotkey daemon. Use `HotKey`.
- ❌ Server backend. Local-only is the moat.
- ❌ Context-aware cleanup in v1. Feature people don't notice when present, notice harshly when wrong.
- ❌ Cross-platform v1. Mac-first, ship, then iOS.
- ❌ Sandbox. AXUIElement insertion needs accessibility, sandbox fights this. Non-sandboxed + notarized + hardened runtime, landit pattern.

---

## 6. Open questions for apple-expert review

1. **AXUIElement insertion vs clipboard+Cmd+V** — is `kAXSelectedTextAttribute` reliable enough across modern apps (VS Code, Slack, Notion, Safari) to be the default, or should we just clipboard-paste with restore?
2. **Models always hot** — is keeping ~5GB resident on a 16GB Mac acceptable, or do we need lazy unload after N minutes idle? Latency cost of reload?
3. **mlx-lm cleanup pass** — Swift native (via mlx-swift), llama.cpp sidecar, or Python sidecar? Native preferred but bundle complexity?
4. **HUD overlay positioning** — can we get caret position reliably across all apps via AX, or is screen-center the only safe default?
5. **Sparkle vs MAU vs in-app updater** — landit went Sparkle. Same here?
6. **CoreML model bundling size** — Whisper-turbo Q4 ~1.5GB. Acceptable bundle size for OSS distribution? Or download on first run with progress UI?
7. **Notarization/codesigning gotchas** — non-sandboxed + accessibility entitlement + microphone entitlement combo, anything to watch for?
8. **WhisperKit streaming API maturity** — is its streaming output good enough that we can drop Kyutai STT and use WhisperKit-native streaming for Track 1?

---

## 7. Risks & mitigations

| Risk                                              | Severity | Mitigation                                                                                    |
| ------------------------------------------------- | -------- | --------------------------------------------------------------------------------------------- |
| LLM cleanup editorializes (rewrites user's voice) | **High** | Strict prompt + 1.5× token cap + skip-on-short. A/B test with 100 utterances before shipping. |
| Whisper hallucinations on silence                 | High     | Silero VAD pre-trim, mandatory.                                                               |
| AXUIElement insertion fails on some apps          | Medium   | Clipboard fallback with restore. Detect failure, log, fall through.                           |
| Memory pressure on 8GB Macs                       | Medium   | Q4 models, optional unload-after-idle setting. M1 base = 8GB unified is the floor.            |
| Accessibility permission UX                       | Medium   | Polished onboarding flow, deep-link to Settings, retry detection.                             |
| First-run model download UX                       | Low      | Bundle in app, no download. Increases DMG to ~2GB but worth it.                               |
| Notarization rejection                            | Low      | Follow landit pattern (non-sandboxed, hardened runtime, notarytool).                          |

---

## 8. Success criteria for v1

- [ ] Author uses Murmur as their primary dictation tool for 1 week without falling back to typing/other tools
- [ ] End-to-end latency p50 < 1.2s, p95 < 1.8s on M2 Pro (revised — see §9)
- [ ] WER on author's accented English audio < 8% (measured on a held-out 50-utterance set)
- [ ] No telemetry, no network calls (verified by Little Snitch)
- [ ] Builds from source on a clean Mac with `swift build`
- [ ] One person other than author has used it for 1 day without filing a P0 issue

---

## 9. Plan revision (post apple-expert review)

Apple-expert returned **REVISE**. Six must-fixes accepted in full. This section overrides anything earlier in the document that conflicts.

### 9.1 Text injection: clipboard-primary, AX-opportunistic

**Was:** "AXUIElement direct insert" listed first, advertised as working for "Most native AppKit apps."

**Now:** clipboard + synthesized Cmd+V is the **default path for everything**. AXUIElement is an opportunistic optimization for a hard-coded allowlist of bundle IDs only:

```swift
let axInsertAllowlist: Set<String> = [
    "com.apple.TextEdit",
    "com.apple.Notes",
    "com.apple.mail",
    "com.apple.dt.Xcode",
    "com.apple.MobileSMS",
    "com.apple.Pages",
]
```

Reasoning: Electron apps (VS Code, Cursor, Slack, Notion, Discord, ChatGPT, Claude desktop, Linear) silently ignore `kAXSelectedTextAttribute` setters. Web inputs in Chrome/Safari only respond to _replace selection_, unreliably. Terminal.app and iTerm2 reject AX writes outright. Clipboard-paste works everywhere those don't.

Clipboard pollution is solved by save→inject→restore-after-500ms, which we were already doing.

### 9.2 Secure input pre-flight (mandatory)

Before any `CGEventPost` of synthesized Cmd+V, check `IsSecureEventInputEnabled()` (private but stable since 10.4). If `true`:

- Abandon injection
- Copy cleaned text to clipboard
- Show HUD: "Secure input active — text copied to clipboard"
- Log to `~/Library/Logs/Murmur/`

This avoids silently-dropped keystrokes during sudo prompts, password fields, 1Password unlock, and iTerm2 "Secure Keyboard Entry" mode.

### 9.3 Track 1 (live transcribed text HUD) — DROPPED from v1

**Was:** "optional for v1, defer to v1.1 if it adds risk."

**Now:** explicitly out of v1. The HUD shows breathing waveform + elapsed timer only. No live text.

Reasoning: Wispr's actual magic is the waveform-and-paste-speed, not the streaming text bubble. Streaming-text rendering with Whisper-final-pass merge logic is its own engineering problem and tries to have it both ways. Decide once: drop it, ship faster.

Track 1 returns as a v2 feature once Kyutai STT 1B MLX integration matures and we can do partial-token rendering without fighting the final paste.

### 9.4 LLM cleanup: llama.cpp + XPC, not mlx-swift, not Python

**Was:** "mlx-lm Swift (via Python bridge for v0.1, native Swift port for v1) OR llama.cpp sidecar — Decision deferred to prototype."

**Now:** **llama.cpp inside an in-bundle XPC service**, period. No Python. No mlx-swift.

|                 | llama.cpp + XPC          | mlx-swift                    | Python sidecar               |
| --------------- | ------------------------ | ---------------------------- | ---------------------------- |
| API stability   | Stable C ABI             | Broke twice in last 6 months | Stable but bundle nightmare  |
| Metal kernels   | Yes                      | Yes                          | Yes via mlx                  |
| Crash isolation | XPC gives free isolation | Same process                 | Multiprocess + TCC issues    |
| DMG bloat       | Minimal (~50MB binaries) | Minimal                      | Heavy (Python runtime ~80MB) |
| Notarization    | Clean                    | Clean                        | Multi-binary signing pain    |

XPC service holds the Qwen2.5-3B Q4_K_M model. Main app talks to it over `NSXPCConnection`. If llama.cpp segfaults on weird input, only the XPC service dies; main app respawns it.

### 9.5 Stub DMG + first-run model download

**Was:** "Bundle in app, no download. Increases DMG to ~2GB but worth it."

**Now:** **50MB stub DMG. Models downloaded on first run from Cloudflare R2.**

Reasoning:

- 4GB DMG is past the abandonment threshold for casual downloads
- GitHub Releases single-asset cap is 2GB anyway
- Notarization on 4GB takes 8–15 minutes per submission; iterating signing fixes becomes painful

Architecture:

- Stub DMG contains app + UI for download progress
- First launch: prompt user, download Whisper-turbo Q4 (~1.5GB) + Qwen2.5-3B Q4 (~2GB) from R2
- Verify SHA256 against signed manifest committed to repo
- Cache to `~/Library/Application Support/Murmur/Models/`
- Delete-and-redownload option in settings if files corrupt

R2 because: free egress for our scale, signed URLs not needed (models are public), Cloudflare's CDN handles long-tail traffic.

### 9.6 Latency budget — honest restatement

**Was:** "<800ms total, ~700ms breakdown."

**Now:** **<1.2s p50, <1.8s p95 on M2 Pro.**

Honest breakdown for a 5-second utterance:

| Stage                                                | Realistic                                            |
| ---------------------------------------------------- | ---------------------------------------------------- |
| VAD silence trim                                     | 30ms                                                 |
| Whisper-large-v3-turbo on ANE (warm, M2 Pro)         | 700–900ms                                            |
| Qwen2.5-3B Q4 cleanup TTFT                           | 100ms                                                |
| Qwen2.5-3B Q4 cleanup decode (50 tokens @ ~60 tok/s) | 800ms (skipped on high Whisper confidence — see 9.8) |
| Clipboard set + Cmd+V synthesis                      | 50ms                                                 |
| **Total p50**                                        | **~1.1s**                                            |

Still beats Wispr's cloud RTT (which is 1.5–3s on consumer ISPs). The 700ms claim was wrong because it counted Qwen at steady-state throughput without TTFT, and used WhisperKit's best-case marketing number not the M2-Pro-after-VAD-trim reality.

### 9.7 Memory: lazy-unload Qwen, keep Whisper hot

**Was:** "Models always hot. ~5GB resident."

**Now:**

- Whisper-turbo Q4 stays hot (~1.5GB) — it's the source of truth, cold-start cost is unacceptable
- Qwen2.5-3B unloads after **90s idle** — reload TTFT is ~400ms, masked by user still speaking
- Steady-state resident: ~1.5GB
- Settings toggle "Aggressive memory mode" for users on 32GB+ → both hot, ~3.5GB resident

5GB always-resident on a 16GB Mac would have been the top GitHub issue. Avoided.

### 9.8 Cleanup-skip heuristic — log-prob, not word count

**Was:** "Skip cleanup for short utterances (<6 words)."

**Now:** Skip cleanup when Whisper's `avg_logprob > -0.3` AND no `[*]` (uncertain segment) tokens. Otherwise run it.

Reasoning: short utterances are exactly where disfluencies hurt most ("um send it"). Confidence-based skipping is the right axis.

### 9.9 Vocabulary expectations — honest

**Was:** "bigger accuracy gain than any model swap."

**Now:** initial*prompt is **prefix conditioning, not lookup**. Real-world gain on proper nouns: 5–15% relative WER reduction. On \_domain* terms (technical jargon): much bigger. Add a post-hoc fuzzy-match correction pass against the vocabulary list as a complement (Levenshtein ≤ 2 → snap to vocabulary term).

### 9.10 Sparkle appcast hosted on Cloudflare Pages, not GitHub raw

**Was:** "Sparkle + GitHub releases."

**Now:**

- DMG assets on GitHub Releases
- `appcast.xml` on Cloudflare Pages (or R2), short TTL
- EdDSA-sign every DMG with `sign_update`, key backed up to two places, never rotated
- Reasoning: GitHub raw CDN can serve stale XML for 5–10 min after push; Sparkle aggressively caches; users would see "update not appearing for hours"

### 9.11 Hotkey lib

**Was:** `HotKey` (sindresorhus).

**Now:** `KeyboardShortcuts` (also sindresorhus, newer, SwiftUI-native).

### 9.12 Pindrop fork → cold-start

**Was:** "Fork Pindrop as starting point."

**Now:** Pindrop is GPL-3. Cold-start. Read it for ideas, don't copy code. Murmur stays MIT.

### 9.13 New v1 scope additions (from apple-expert "Missing")

Promoted from out-of-scope to in-scope for v1:

- **Raw-vs-cleaned undo** — ring buffer of last 10 raw transcripts, hotkey to re-paste raw
- **Privacy manifest** — `PrivacyInfo.xcprivacy` with required-reason API declarations
- **Multi-display caret positioning** — `NSScreen.screens` lookup before HUD presentation
- **Hotkey held >60s cap** — beep, finalize, refuse longer captures
- **Local crash reporting** — `NSSetUncaughtExceptionHandler` + signal handlers, write to `~/Library/Logs/Murmur/`, link to GitHub issue template
- **Login-item opt-in** — `SMAppService.mainApp.register()`, off by default
- **Sequoia/Tahoe TCC handling** — `AXIsProcessTrustedWithOptions` check on launch, deep-link to settings if revoked, consistent code signing across releases

Dictation commands ("new line", "period", "scratch that") **deferred to v1.1** — Whisper produces punctuation natively most of the time; explicit commands are a polish item, not v1-critical.

---

## 10. Universal injection — the v2 vision (this is the moat)

**The strategic insight:** Wispr Flow is also a clipboard-paste tool. So is every other dictation app on the market. If Murmur stops at clipboard-paste, we're playing parity, not winning.

The real moat — and the user's stated long-term goal — is making Murmur work **anywhere a Mac accepts text input**, including the places clipboard-paste fails or feels janky: secure inputs, terminal command-line editing, password manager unlock fields, in-app inline replacement, IME-mediated input contexts.

There are five real paths to "everywhere." We commit to the first three for v1; we research path 4 during v1; we ship path 4 for **v2**, which is the version that takes Wispr's lunch.

### Path 1 — Clipboard + ⌘V (v1 default)

Already covered. Universal coverage of normal text fields. ~95% of apps. Fails: secure inputs, some games, some IME-mediated fields.

### Path 2 — AXUIElement direct insertion (v1 opportunistic)

Already covered. Allowlist of native AppKit apps where AX text setters actually work.

### Path 3 — Synthesized per-character keystrokes (v1 fallback)

`CGEventCreateKeyboardEvent` per Unicode code point. Slow (~30 chars/sec usable), but works in secure inputs after `IsSecureEventInputEnabled()` clears, and works in apps that block paste. The "always last resort" path.

### Path 4 — **Input Method Kit (IMK) — the v2 unlock**

The architectural move that beats Wispr structurally: **register Murmur as a macOS input method.**

This is how Chinese, Japanese, Korean IMEs ship. They register with the system's Text Services Framework. From that point on, _every text field in every app_ — including secure inputs, terminals, IME-mediated fields, and apps that block accessibility — receives text from the IME via the same private OS pathway used by the keyboard.

**Implications:**

- Coverage goes from ~95% → effectively 100%. Including iTerm2's terminal grid, which currently rejects everything.
- No more clipboard pollution, ever. Inline commit, native to the field.
- No accessibility permission needed for injection. (We still need it for caret position to place the HUD.)
- Inline composition mark-up possible — the user can see in-progress dictation render directly inside the focused text field, like IME candidate windows. This is the "feels native" UX Wispr cannot match without rebuilding.
- Switchable as an input source via the menu-bar globe icon, alongside other keyboards. Premium feel — feels like a system feature, not a third-party hack.

**Cost:**

- IMK is a 20-year-old AppKit API with sparse modern documentation. The reference implementations are Apple's own (NotABento, etc.) and a handful of third-party CJK IMEs. Steep learning curve.
- Stricter sandboxing model — IMEs are XPC-launched by the OS, with their own lifecycle.
- Distribution: IMEs install to `~/Library/Input Methods/` and require user activation in System Settings → Keyboard → Input Sources. We need to make this onboarding flawless.
- Code signing requires the `com.apple.HIToolbox.input-method` entitlement and specific Info.plist keys (`InputMethodConnectionName`, `tsInputMethodCharacterRepertoireKey`, etc).

**Why we don't do it for v1:**

Two reasons. First, IMK is a multi-week build on its own — it would push v1 past the three-weekend window. Second, we want to validate the dictation UX with the simpler clipboard path first, then bring IMK in _after_ the core loop is loved. Otherwise we're shipping unproven UX through a complex transport.

**Architecture for v2:**

- Murmur splits into two bundles:
  - `Murmur.app` — main app, model service, settings, HUD, capture pipeline
  - `MurmurIME.app` — input method bundle, lives in `~/Library/Input Methods/`, talks to Murmur.app over XPC
- Murmur.app's existing pipeline produces clean text. The IME bundle receives it and commits via `IMKInputController.client().insertText(_:replacementRange:)`.
- Inline composition (showing partial text inside the focused field as you speak) is possible in v2.5 by emitting `setMarkedText` updates from the streaming track once we re-enable Track 1.

### Path 5 — Per-app bridges (long-tail)

For specific stubborn apps where neither IMK nor paste behaves well (rare), ship per-app bridges: AppleScript for Mail/Numbers, Slack-specific message-API bridge, etc. We add these reactively based on user reports. Not a v2 commitment.

### Coverage comparison

| Surface                        | v1 (paste + AX + keystroke) | v2 (+ IMK)                                     |
| ------------------------------ | --------------------------- | ---------------------------------------------- |
| TextEdit, Notes, Mail          | AX direct (premium)         | AX direct (unchanged)                          |
| VS Code, Cursor, Slack, Notion | Paste                       | IMK direct, inline                             |
| Chrome, Safari, web inputs     | Paste                       | IMK direct, inline                             |
| Terminal.app                   | Paste                       | IMK direct                                     |
| iTerm2                         | Paste (occasionally weird)  | IMK direct                                     |
| 1Password unlock, sudo prompt  | **Refused (secure input)**  | **Refused (we still won't dictate passwords)** |
| Vim insert mode                | Paste                       | IMK direct, no register pollution              |
| Tmux/SSH inside Terminal       | Paste (keystroke-level)     | IMK direct                                     |
| Games / SDL apps               | Per-character keystroke     | Per-character keystroke (IMK doesn't reach)    |

**What this gives us as a product position:**

- _v1_: "A free local Wispr Flow." Comparable to Wispr, better on accents and privacy.
- _v2_: "The dictation system Mac never had." Genuinely uncopyable by Wispr without them rebuilding their architecture, because Wispr is fundamentally a cloud + clipboard product. An IMK-based local dictation tool is structurally different.

This is the bet. v1 ships the loop and proves the UX. v2 makes it impossible to go back to typing.
