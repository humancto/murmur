# Plan — `demoable-v0.1-vertical-slice`

**Roadmap items grouped:** 8, 9, 10 of v0.1. Single PR that ships a runnable Murmur app: hold hotkey → speak → release → text appears in focused field.

## Goal

Take the user from "all the pieces are tested in isolation" to "open Murmur.app, bind a hotkey in Settings the OS prompts you for, hold it, speak, release, watch text appear in TextEdit / VS Code / Slack."

## What ships

```
Sources/Murmur/                   ← rewritten — was a CLI; becomes an AppKit app
├── main.swift                    (replaces print-and-exit; runs NSApplication)
├── AppDelegate.swift             (new — orchestrates the dictation lifecycle)
├── HUDController.swift           (new — owns the floating NSPanel)
├── HUDView.swift                 (new — SwiftUI waveform/state view)
├── MenuBarController.swift       (new — owns NSStatusItem)
├── DictationCoordinator.swift    (new — wires hotkey → capture → trim → transcribe → inject)
└── Onboarding.swift              (new — first-run mic + accessibility prompts)

Tests/MurmurCoreTests/
└── DictationCoordinatorTests.swift  (new — wiring tests with all hooks injected)

README.md                          (build/run/usage section refreshed)
```

## Architectural choices

### NSApplicationMain shape

```swift
// main.swift
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar app, no Dock icon
app.run()
```

`.accessory` activation policy keeps Murmur out of the Dock and Cmd+Tab — it's a menu-bar utility, not a foreground app.

### Component ownership

```
AppDelegate
├── owns: HUDController, MenuBarController, DictationCoordinator
└── on launchFinish:
       1. Run Onboarding.checkAndPrompt()  (mic + AX permissions)
       2. MenuBarController.install()
       3. DictationCoordinator.start()  (registers hotkey listener)

DictationCoordinator
├── owns: AudioCapture (actor), VAD, AXInjector, ClipboardInjector, settingsStore
├── observes KeyboardShortcuts.onKeyDown / onKeyUp for .dictate
├── on keyDown:  await capture.start(); HUD.show(state: .recording)
├── on keyUp:    let (samples, didCap) = await capture.stop()
│                   HUD.update(state: .processing)
│                   let trimmed = vad.trim(samples)
│                   transcribe(trimmed) → cleanedText
│                   inject(cleanedText)  // AX-first, fallback to clipboard
│                   HUD.hide()
└── transcription: WhisperKit on small-en model for v0.1 (faster startup,
                   accurate enough for the demo; large-v3-turbo is v0.5)
```

### HUD design (minimal)

`NSPanel` with:

- `.floating` window level
- `.hudWindow` material via `NSVisualEffectView`
- `ignoresMouseEvents = true` (click-through)
- 220×72 pixel pill shape, 14 pt corner radius, centered horizontally on the screen with the focused window, 80 px above its caret (or screen-bottom-center if caret unavailable)
- SwiftUI content: 8 vertical bars whose heights breathe with a sine wave; tinted by state
  - `.idle`: invisible (HUD hidden)
  - `.recording`: warm amber, breathing
  - `.processing`: dim cream, slow pulse
  - `.error`: signal red, two short pulses then hide

Reduced motion: bars become 8 dots that fade in/out instead of breathing.

### Menu bar

`NSStatusItem` length = `NSStatusItem.variableLength`:

- Icon: SF Symbol `mic` (idle) / `mic.fill` with a red badge dot (recording)
- Click → menu:
  - "Bind hotkey…" (opens KeyboardShortcuts.Recorder window)
  - "Vocabulary…" (placeholder, posts a "coming in v0.5" alert)
  - "Settings…" (placeholder, posts "v0.5")
  - "About Murmur"
  - "Quit"

### Onboarding

First launch only. Three sequential alerts, each gated on the prior:

1. **Microphone:** `AVCaptureDevice.requestAccess(for: .audio)`. If denied, show alert with deep link to Settings → Privacy → Microphone, exit.
2. **Accessibility:** `AXIsProcessTrusted` — if false, show alert with `AXIsProcessTrustedWithOptions([.kAXTrustedCheckOptionPrompt: true])` and a deep link to System Settings → Privacy → Accessibility. Wait for the user to grant, polling every 2 seconds, with a "Continue" button that re-checks.
3. **Hotkey:** open the `KeyboardShortcuts.Recorder` panel for `.dictate`, prompting the user to press a key combo. Save and dismiss.

Onboarding state persisted in `Settings.didCompleteOnboarding: Bool` (added to `Settings`).

### Transcription

For v0.1 we ship `WhisperKit(model: "openai_whisper-base.en")` — `base.en` is ~150 MB, downloads in seconds, accurate enough for the demo, and fast enough on M1 base hardware to feel responsive. `large-v3-turbo` (the architecture-plan target) is a v0.5 swap once the first-run download UI lands.

WhisperKit downloads the model on first transcription call into `ModelCache.production.baseDirectory` (we created the helper in PR #2 — finally consume it). Subsequent calls use the cached copy.

### LLM cleanup pass

**Deferred to v0.5.** v0.1 ships Whisper output verbatim. The architecture-plan §2.2 cleanup pass requires llama.cpp + XPC + a 2 GB Qwen model — significant work that doesn't gate "the tool works." Whisper's `.en` models punctuate well enough to be usable.

## Tests

`DictationCoordinatorTests.swift` exercises the wiring with every component injected:

1. **`keyDown starts capture and shows HUD`** — capture mock asserts `start()` called, HUD mock asserts `.recording` state.
2. **`keyUp runs the pipeline and injects via AX when on allowlist`** — full sequence with AXInjector returning `.inserted`, ClipboardInjector mock NOT called.
3. **`keyUp falls back to clipboard when AX returns .unsupportedApp`** — AXInjector mock returns `.unsupportedApp`, ClipboardInjector mock asserts called with the same text.
4. **`empty trimmed samples skip transcription and injection`** — VAD mock returns `[]`, transcribe mock NOT called, inject mocks NOT called.

The HUD and MenuBar are touched only via injected protocol-typed coordinators; we don't try to snapshot SwiftUI views in v0.1 (snapshot test infra is its own item).

## Acceptance criteria

- [ ] Sources/Murmur/ rebuilt as an AppKit app
- [ ] `swift run Murmur` opens (no Dock icon — appears as menu bar item only)
- [ ] First launch: 3-step onboarding (mic / AX / hotkey)
- [ ] Hold the bound hotkey, speak for ≥1 second, release — text appears in TextEdit
- [ ] Verified manually on at least: TextEdit (AX path), VS Code (clipboard fallback)
- [ ] All 44 prior tests still pass + 4 new DictationCoordinator tests = 48 total
- [ ] `swift build -c release` produces a working binary
- [ ] README updated with usage section ("how to actually try it")
- [ ] Branch: `feat/demoable-v0.1-vertical-slice`
- [ ] Single squash-merged PR

## Risks

- **WhisperKit model download is async** — first dictation will hang for ~5–10 s on a slow connection. The HUD must show a loading state, not just spin silently. Mitigated by triggering the download eagerly on app launch (background task) so by the time the user hits the hotkey, the model is cached.
- **AppKit app bundle vs `swift run`** — `swift run Murmur` works for a CLI but `NSStatusItem` and accessibility APIs need the app to register with the OS as a real `LSUIElement` agent. **`Info.plist` must be embedded in the SPM build product**, which SPM doesn't do natively for executable products on macOS. Workaround: post-build script that creates a `.app` bundle wrapper, OR ship a `Makefile`/`build.sh` that builds the bundle. Alternatively: use `.app` only when the user runs the convenience script; `swift run` directly will work for development but won't have a Dock-less menu-bar presence (it'll appear as a foreground app). For v0.1 we ship `build.sh` that produces `Murmur.app` in `./build/`.
- **Sendable across actors** — `DictationCoordinator` is `@MainActor` (it touches AppKit) but calls into the `AudioCapture` actor. Awaits across the boundary; no cross-actor mutable state.
- **Hotkey registered before user binds it** — `KeyboardShortcuts.Name.dictate` has no default. If the user dismisses the onboarding hotkey-recorder, no capture ever fires. The menu-bar "Bind hotkey…" entry is the recovery path. Document.
- **Mic permission revocation mid-session** — if the user revokes mic access in System Settings while the app is running, the next `start()` throws. Surface as a toast in the HUD, then re-trigger onboarding step 1.

## Open questions for apple-expert

1. **`.accessory` activation policy vs `.regular` with `LSUIElement`** — both hide the Dock icon; which is the modern preferred form?
2. **Onboarding UX** — three sequential modal alerts vs a single SwiftUI window with three steps. Modal alerts are crude but trivial; the SwiftUI flow is v0.5 polish. Push back if you'd rather force the polished version now.
3. **WhisperKit model choice** — `base.en` vs `small.en` vs `large-v3-turbo`. `base.en` is fast and small but accent quality may be poor. `small.en` is the better balance. Recommend.
4. **Eager vs lazy model download** — eager (on launch) makes first dictation instant but burns bandwidth on every user; lazy with a HUD spinner is honest but laggy. v0.1 default?
5. **`.app` bundle build script** — single `build.sh` that wraps `swift build` + bundle scaffolding, or a proper `Bundle.swift` plugin? `build.sh` is fastest; the plugin is cleaner long-term.
6. **`DictationCoordinator` actor isolation** — `@MainActor` because of AppKit, but the audio pipeline is on its own actor. Any concurrency hazard you see?
7. **Hotkey unbound state** — should the menu bar icon flash a red exclamation on launch if the user has no binding?
8. **Anything missing for "demoable on stage"** that I'm under-thinking.
