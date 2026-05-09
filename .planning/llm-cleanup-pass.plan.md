# Plan — `llm-cleanup-pass`

**Roadmap item:** First v0.5 item. The "feels like Wispr Flow" upgrade. Whisper output goes through Qwen2.5-3B-Instruct via `llama.cpp` for a strict cleanup pass between transcribe and inject.

## Goal

Take Whisper's verbatim output (`"um so I think we should uh ship the the new feature next week"`) and turn it into clean prose (`"So I think we should ship the new feature next week."`) — without the LLM rewriting the user's voice.

The architecture-plan §2.2 prompt is load-bearing and verbatim:

```
Fix punctuation, capitalization, and remove obvious disfluencies
(um, uh, like-as-filler, repeated words). DO NOT rephrase.
DO NOT substitute vocabulary. DO NOT add or remove information.
Preserve technical terms exactly. Output only the cleaned text.
```

T=0, top_p=1, output capped at 1.5× input tokens.

Confidence-based skip per §9.8: when Whisper's avg log-prob > -0.3, skip cleanup (the transcript is already high-confidence and the LLM is more likely to introduce errors than fix them).

## What ships

```
Package.swift                         (+ mattt/llama.swift dep on MurmurCore)
Sources/MurmurCore/
├── Cleaner.swift                     (new — protocol + skip-on-short heuristic)
├── LlamaCppCleaner.swift             (new — actor wrapping llama_context)
├── DictationCoordinator.swift        (modified — adds cleaner injection)
└── ModelCache.swift                  (unchanged — already resolves Models/)

Tests/MurmurCoreTests/
└── CleanerTests.swift                (new — stub-driven tests for the prompt + cap + skip logic)
```

No new executable code in the `Murmur` target — the AppDelegate just constructs `LlamaCppCleaner` and passes it to `DictationCoordinator`, then surfaces a "downloading cleanup model…" state in the menu bar (similar to the WhisperKit warm-up).

## Dependency

```swift
.package(url: "https://github.com/mattt/llama.swift.git", from: "2.9090.0"),
```

`mattt/llama.swift` is an SPM-native semantic-version wrapper around `llama.cpp` (xcframework binary target). swift-tools-version 6.0, macOS 13+, latest tag `2.9090.0` (released today, 2026-05-09). The "2.9090" maps to llama.cpp release `b9090`.

Trade-offs apple-expert needs to weigh:

- **Pro:** binary target, no C/C++ build chain, Metal kernels included, semantic versioning, active maintenance (Mattt Thompson).
- **Pro:** library is a thin re-export of llama.cpp's C API. We write the higher-level wrapper ourselves (~250 lines), keeping it tight to our needs.
- **Con:** binary target means we trust upstream's xcframework. Verifiable via the SHA in `Package.swift`.
- **Con:** ~150 MB xcframework added to dev `swift build` checkouts (not the shipping `.app`).

Alternative: `profclaw/swift-llama` ("Actor-safe. Streaming. Tool-calling.") looks higher-level but only 2 stars and unverified maturity. **Sticking with `mattt/llama.swift` for predictability.**

## Cleaner protocol

```swift
public import Foundation

public protocol Cleaner: Sendable {
    /// Clean up disfluencies and punctuation in `text`. Returns `text`
    /// verbatim if cleanup should be skipped (high Whisper confidence,
    /// extremely short input, etc).
    ///
    /// `whisperLogProb` is the avg log-prob from Whisper, used for
    /// confidence-based skip per architecture-plan §9.8. Pass `nil` to
    /// disable skipping.
    func clean(text: String, whisperLogProb: Float?) async throws -> String
}

public enum CleanerError: Error, Sendable {
    case modelNotLoaded
    case generationFailed(String)
    case outputCapExceeded   // model went over the 1.5× token cap, emergency cutoff
}
```

## LlamaCppCleaner actor (sketch)

```swift
@preconcurrency package import LlamaSwift  // imports the underlying llama.cpp C API
public import Foundation
private import os

public actor LlamaCppCleaner: Cleaner {

    public let modelURL: URL
    public let confidenceSkipThreshold: Float = -0.3   // §9.8
    public let outputCapMultiplier: Double = 1.5
    public let minInputCharsToClean: Int = 25          // skip very short utterances

    private var model: OpaquePointer?     // llama_model*
    private var context: OpaquePointer?   // llama_context*
    private var loadTask: Task<Void, any Error>?

    private static let log = Logger(subsystem: "dev.murmur", category: "cleaner")
    private static let systemPrompt = """
        Fix punctuation, capitalization, and remove obvious disfluencies \
        (um, uh, like-as-filler, repeated words). DO NOT rephrase. \
        DO NOT substitute vocabulary. DO NOT add or remove information. \
        Preserve technical terms exactly. Output only the cleaned text.
        """

    public init(modelURL: URL) {
        self.modelURL = modelURL
    }

    /// Pre-warm the model. Concurrent callers de-duplicate via shared loadTask.
    public func warmUp() async throws {
        if model != nil { return }
        if let existing = loadTask { try await existing.value; return }

        let url = self.modelURL
        let task = Task { [weak self] in
            try await self?.loadModelOffActor(at: url)
        }
        loadTask = task
        try await task.value
    }

    // Load happens off-actor because llama_model_load is blocking; we
    // re-enter the actor with `assignModelAndContext` to store the
    // (non-Sendable, opaque) pointers as actor-private state.
    nonisolated private func loadModelOffActor(at url: URL) async throws {
        // Use llama.cpp C API to load. Pseudocode — actual calls
        // documented in `llama.h` and verified during implementation.
        // model = llama_model_load_from_file(url.path, default_params)
        // context = llama_init_from_model(model, default_context_params)
        // ...
        // await self.assignModelAndContext(model, context)
        fatalError("see implementation; this is the plan sketch")
    }

    public func clean(text: String, whisperLogProb: Float?) async throws -> String {
        // Skip on confidence
        if let lp = whisperLogProb, lp > confidenceSkipThreshold {
            Self.log.debug("Cleanup skipped: high Whisper confidence (\(lp))")
            return text
        }
        // Skip on length
        if text.count < minInputCharsToClean {
            Self.log.debug("Cleanup skipped: short input (\(text.count) chars)")
            return text
        }
        try await warmUp()
        guard let context else { throw CleanerError.modelNotLoaded }

        // Tokenize the chat template:
        //   <|im_start|>system\n{systemPrompt}<|im_end|>
        //   <|im_start|>user\n{text}<|im_end|>
        //   <|im_start|>assistant\n
        //
        // Decode tokens until <|im_end|> or until output_token_count
        // exceeds inputTokenCount * outputCapMultiplier.

        // ... 100ish lines of llama.cpp decode loop ...

        return cleanedText
    }
}
```

The full implementation is ~250 lines because the llama.cpp C API is low-level — model load, context create, tokenize, KV-cache manage, logits sample (greedy at T=0), detokenize, free. Standard.

## DictationCoordinator integration

```swift
// new init param:
public init(
    capture: AudioCapture,
    vad: VAD = VAD(),
    transcriber: any Transcribing,
    cleaner: (any Cleaner)? = nil,        // NEW — optional, off by default
    primaryInjector: any TextInjecting,
    fallbackInjector: any TextInjecting,
    hud: (any DictationHUDPresenting)?,
    initialPromptProvider: @escaping @Sendable () -> String? = { nil }
)

// in handleKeyUp(), after transcribe:
if let cleaner {
    do {
        text = try await cleaner.clean(text: text, whisperLogProb: nil)
        // (whisperLogProb plumbing requires a Transcribing return-type
        //  change — punted to a follow-up; for v0.5 first cut we always
        //  attempt cleanup unless the user disabled it in Settings.)
    } catch {
        Self.log.error("Cleanup failed; using raw: \(String(describing: error))")
        // fall through with `text` unchanged
    }
}
```

Failure mode is "use raw Whisper output" — never block injection on cleanup failure.

## Settings change

`Settings` gains:

```swift
public var llmCleanupEnabled: Bool          // default false in v0.5; flip true once
                                            // we've verified prompt drift on real audio
public var llmCleanupModelPath: String?     // optional override; nil = production default
```

Forward-compat decode handles missing fields. UI for the toggle ships in the `settings-window` v0.5 item.

## Tests (8)

`CleanerTests.swift` — uses a `StubCleaner` plus a real `LlamaCppCleaner` with the model gated by `MURMUR_HAS_LLM_MODEL` env var (similar to `MURMUR_SKIP_AUDIO_HARDWARE`):

1. **`Cleaner protocol — high-confidence skip`** — stub asserts `clean` returns input verbatim when `whisperLogProb > -0.3`.
2. **`Cleaner protocol — short input skip`** — stub-driven, input < 25 chars returns verbatim.
3. **`Cleaner protocol — long uncertain input cleans`** — stub returns transformed text.
4. **`coordinator integration — cleanup applied`** — `DictationCoordinator` calls cleaner; injected text is the cleaner's output, not the transcriber's raw output.
5. **`coordinator integration — cleaner failure falls through to raw`** — cleaner stub throws; coordinator injects raw transcribe output.
6. **`coordinator integration — no cleaner means raw output`** — coordinator constructed without cleaner; injects raw verbatim.
7. **`LlamaCppCleaner — gated end-to-end`** — gated by `@Test(.disabled(if: !hasLLMModel))`. Loads a real Qwen2.5-3B Q4 from `~/Library/Application Support/Murmur/Models/Qwen2.5-3B-Instruct-Q4_K_M.gguf` and asserts a known input transforms predictably.
8. **`LlamaCppCleaner — output cap honored`** — same gate; long input that the model would naturally rewrite extensively gets cut off at `1.5×` and returns whatever was emitted to that point.

## Acceptance criteria

- [ ] `Package.swift` adds `mattt/llama.swift` `from: "2.9090.0"` on `MurmurCore`
- [ ] `Sources/MurmurCore/Cleaner.swift` exists (protocol + errors)
- [ ] `Sources/MurmurCore/LlamaCppCleaner.swift` exists (actor; load + clean + dispose)
- [ ] `DictationCoordinator` accepts an optional `cleaner` and routes through it on `handleKeyUp`
- [ ] `Settings` gains `llmCleanupEnabled` field with forward-compat decode
- [ ] `Tests/MurmurCoreTests/CleanerTests.swift` — 8 swift-testing tests, hardware-gated where appropriate
- [ ] `swift build` clean, no warnings
- [ ] `swift test` exits 0 (49 prior + 8 new = 57)
- [ ] `./scripts/make-app.sh` still produces a working bundle
- [ ] **Manual end-to-end:** with `MURMUR_HAS_LLM_MODEL=1` and the Qwen GGUF in `~/Library/Application Support/Murmur/Models/`, the dictation loop in `Murmur.app` runs through cleanup and produces cleaned text in the focused field.
- [ ] Branch: `feat/llm-cleanup-pass`
- [ ] Single squash-merged PR

## Risks

- **C API wrapping is the load-bearing complexity.** ~250 lines of careful FFI: pointer ownership, KV cache, tokenization edge cases, sampling at T=0 (deterministic argmax). Tests for each layer; small, focused functions.
- **Qwen2.5-3B Q4 is ~2 GB.** First-run download UX is a separate v0.5 item. For _this_ PR, the cleaner's `warmUp()` throws if the model file is missing; the AppDelegate surfaces it as "Cleanup unavailable" in the menu bar and continues without cleanup. No download UI yet.
- **Prompt drift.** The architecture-plan prompt is strict, but Qwen-3B may still rewrite voice. Mitigations in code: T=0 (deterministic), output cap at 1.5× input tokens (hard ceiling), confidence-based skip, length-based skip, fall-through-on-error. Empirical: the user A/Bs raw vs cleaned output across their first week of use.
- **`@preconcurrency package import LlamaSwift`** — same Sendable concerns as AVFoundation/AppKit/KeyboardShortcuts. The C-API pointers are non-Sendable; we wrap them in actor-private state and never let them escape.
- **In-process vs XPC.** Architecture-plan §9.4 said llama.cpp + XPC for crash isolation. v0.5 ships in-process — XPC is meaningfully more complex (separate bundle, NSXPCConnection, encoding). If real-world use shows segfaults on weird input, XPC is the v1.0 escape hatch.
- **Memory pressure.** Qwen-3B Q4 is ~2 GB resident. Architecture-plan §9.7 said unload after 90 s idle. v0.5 first cut: keep loaded for the session; v0.5.1 follow-up adds the idle-unload.
- **WhisperKit `whisperLogProb` plumbing.** Whisper's `TranscriptionResult` exposes `avgLogprob`; the current `Transcribing` protocol returns `String` only. Plumbing it through is a small change but cross-cuts. v0.5 first cut passes `nil` (always cleanup); v0.5.1 wires the real value once the integration is proven.

## Apple-expert revisions applied

Verdict was **REVISE** with no showstoppers but several correctness, distribution, and prompt-engineering items that must land in this PR. Applying:

### Scope re-budget

- C-API wrapping is **~400 lines, not 250.** Naive `String(cString:)` per `llama_token_to_piece` corrupts multi-byte UTF-8 (emoji, Devanagari) — accent-first product cannot ship that. Accumulate raw bytes into `[UInt8]`, validate UTF-8 at safe flush boundaries.

### Correctness must-fixes

- **Token cap math** uses `llama_tokenize` count of the rendered prompt, not `text.count / 4` heuristic. Floor at `max(ceil(1.5 × inputTokens), 16)` so the cap doesn't fire on every short utterance.
- **KV cache lifetime:** `llama_free(context)` **before** `llama_model_free(model)` (reverse is use-after-free). `llama_kv_self_clear(context)` between every `clean(...)` call so prior utterance's KV doesn't bleed into the next.
- **`loadTask` retention:** clear `loadTask = nil` on success (not just failure — the WhisperKitTranscriber pattern from PR #8 has this same latent bug; preempt for the future idle-unload work).
- **Empty-output safety:** if the first sampled token is `<|im_end|>` (degenerate case), return raw input verbatim — do **not** fall back to temperature. Determinism is the whole pitch.

### Prompt revision

Append the one-shot example to the system prompt — Qwen2.5-Instruct prefaces "Sure, here is the cleaned text:" on ~12% of dictation-style inputs without it; <1% with it. ~80 extra prompt tokens, worth it:

```
Fix punctuation, capitalization, and remove obvious disfluencies
(um, uh, like-as-filler, repeated words). DO NOT rephrase.
DO NOT substitute vocabulary. DO NOT add or remove information.
Preserve technical terms exactly. Output only the cleaned text.
Do not preface, do not explain.

Example:
Input: "um so I think we should uh ship the the new feature next week"
Output: "So I think we should ship the new feature next week."
```

### Distribution must-fix

- **`make-app.sh` must traverse embedded llama.cpp dylibs and re-sign with `codesign --force --options runtime`** before stapling. Without this, notarization rejects the bundle. Plus an explicit acceptance criterion to verify on PR.

### Idiom

- `confidenceSkipThreshold` becomes an init parameter (default `-0.3`) so tests can drive both branches without depending on the hardware gate.

### Follow-ups (linked from PR description, not in this PR)

- `feat/whisper-logprob-plumb` — thread `avgLogprob` through `Transcribing` so §9.8 confidence skip can fire. Without it, cleanup runs on every utterance when enabled. Default-on flip in v0.5.1 gates on this issue.
- `feat/qwen-idle-unload` — §9.7 unload after 90 s idle. Memory pressure gate before flipping `llmCleanupEnabled` default to true.
- `feat/cleaner-xpc-isolation` — §9.4 XPC service for crash isolation. v1.0 work.

### Acceptance gates added

- `make-app.sh` re-signs all embedded dylibs with `--options runtime` (verified by `codesign --display --verbose=4` showing `flags=0x10000(runtime)` on each)
- Disposal documented inline: `llama_free(context)` then `llama_model_free(model)`
- `llama_kv_self_clear` called between every `clean(...)` invocation
- Token cap uses `llama_tokenize` and floors at 16
- One-shot example added to system prompt verbatim
- Empty-output (immediate `<|im_end|>`) returns raw input
- Memory pressure gate: 16 GB Mac with Chrome + Slack + VS Code stays green through 5 dictation cycles before flipping default-on

## Open questions for apple-expert (resolved in review)

1. **`mattt/llama.swift` vs alternative wrappers.** Is the ~250-line hand-written Swift wrapper around the C API the right call, or is there a higher-level wrapper (`profclaw/swift-llama`, the SwiftUI sample in llama.cpp's repo, `LlamaKit`-style packages) that would save us 200 lines? My instinct is hand-written stays closest to our needs and matches the architecture plan's "stable C ABI" rationale.
2. **In-process vs XPC for v0.5.** Plan §9.4 says XPC. v0.5 ships in-process to keep the PR shippable. Push back if you think the XPC complexity must land here.
3. **`whisperLogProb` plumbing — punt to v0.5.1?** Currently the cleaner skip-on-confidence threshold (§9.8) can't fire because Whisper's logprob isn't propagated. Plumbing it requires changing `Transcribing.transcribe` to return a struct, not a String. Worth doing in this PR or as a follow-up?
4. **Idle unload.** Plan §9.7 says unload Qwen after 90 s. v0.5 first cut: keep loaded for the session. Right call?
5. **`llmCleanupEnabled` default.** Off by default in v0.5 (so users get a working tool, then opt in to cleanup). On by default once we've validated prompt drift. Right phasing?
6. **Memory budget on 16 GB Macs.** Whisper hot (~480 MB) + Qwen Q4 (~2 GB) = ~2.5 GB resident. Plan §9.7 said this is fine. Verify once more — is 2.5 GB on 16 GB still our floor?
7. **The strict prompt itself.** Architecture-plan §2.2 verbatim. Anything you'd change in light of 6 months of additional Qwen-2.5 community findings?
8. **Anything missing.** Sampling strategy beyond greedy-at-T=0? Stop tokens beyond `<|im_end|>`? Temperature fallback if greedy generates `<|im_end|>` immediately?
