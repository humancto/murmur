# Plan — `swift-package-skeleton`

**Roadmap item:** `- [ ] swift-package-skeleton` (first item, milestone v0.1).

**Goal:** A buildable, testable Swift Package that produces a macOS 14+ executable named `Murmur`. `swift build` clean, `swift test` runs and passes against a single asserting version test. No business logic — purely the foundation every other v0.1 item builds on.

## What ships

```
murmur/
├── Package.swift                  ← SPM manifest, macOS 14 executable + library + test target
├── Sources/
│   ├── MurmurCore/                ← library, all logic, all public API
│   │   └── MurmurInfo.swift       ← public struct with `version` and `bundleIdentifier`
│   └── Murmur/                    ← thin executable that imports MurmurCore
│       └── main.swift             ← @main on a plain struct, prints version, exits 0
├── Tests/
│   └── MurmurCoreTests/
│       └── MurmurInfoTests.swift  ← swift-testing, three asserting tests
└── .swift-version                 ← "6.0" (pin for CI / contributors)
```

## Package.swift sketch (revised — apple-expert review)

```swift
// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),                              // explicit, survives toolchain bumps
    .enableUpcomingFeature("ExistentialAny"),             // cheap on a clean codebase
    .enableUpcomingFeature("InternalImportsByDefault"),   // ditto
]

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Murmur", targets: ["Murmur"]),
        .library(name: "MurmurCore", targets: ["MurmurCore"]),
    ],
    targets: [
        .executableTarget(
            name: "Murmur",
            dependencies: ["MurmurCore"],
            path: "Sources/Murmur",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "MurmurCore",
            path: "Sources/MurmurCore",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MurmurCoreTests",
            dependencies: ["MurmurCore"],
            path: "Tests/MurmurCoreTests",
            swiftSettings: swiftSettings
        ),
    ]
)
```

**Apple-expert revisions applied:**

- Dropped `.enableExperimentalFeature("StrictConcurrency")` — that's a Swift-5-staging flag that no-ops (or worse, warns) under `swift-tools-version: 6.0`.
- Pinned `.swiftLanguageMode(.v6)` explicitly — survives default-mode shifts in future toolchains.
- Added `.enableUpcomingFeature("ExistentialAny")` and `InternalImportsByDefault` — free wins on day-zero code.
- Split into `MurmurCore` library + thin `Murmur` executable. Tests target the library; no `@testable` needed; future XPC service can depend on `MurmurCore` directly.

## Key technical decisions

- **`swift-tools-version: 6.0`.** Strict concurrency is on by default at language mode v6; explicit `.swiftLanguageMode(.v6)` pin makes it survive toolchain default shifts.
- **`.macOS(.v14)`** as the floor. **Locked here, not lower, not higher.** WhisperKit is the binding constraint (CoreML compute units + MPS graph features it depends on landed in 14). 13 would mean carrying dead branches we'd revert next PR; 15+ would cut install base for nothing v0.1 needs.
- **`MurmurCore` library + thin `Murmur` executable.** Cost is ~5 lines of `Package.swift` now; benefit is testability without `@testable`, clean import boundary, and a target for the future XPC service to depend on.
- **`@main` on a plain struct** (not `NSApplicationMain`, not SwiftUI `App`). YAGNI for v0.1; the AppKit swap when the HUD/menu-bar items land is mechanical (~10 lines, no migration risk).
- **Bundle identifier locked: `com.archithrapaka.murmur`.** Sparkle keys updates by it, TCC pins consent grants to it, notarization tickets are scoped to it. Migrating it later would force every existing install to re-grant Accessibility/Microphone and confuse Sparkle's update channel. Set once, never change.
- **`swift-testing` (`@Test`, `#expect`)** instead of XCTest for new tests. Ships with Xcode 16, requires `swift-tools-version: 6.0` (we have it). Three tests is the right place to start the habit.

## What this does NOT include

- WhisperKit dependency — that's the next roadmap item.
- Hotkey, audio capture, HUD, menu bar, injectors — all later items.
- App bundle / Info.plist — `swift build` produces a CLI binary; bundling is a v1.0 packaging concern. The roadmap items between here and there will introduce AppKit (`NSApplication.shared.run()`) and shift to a proper `.app` shape. Don't pre-build that scaffolding now.
- CI workflow file — out of scope; can be added in a separate roadmap chore later.

## Tests (mandatory — no "trust CI" excuses)

Single test file `MurmurInfoTests.swift`, using `swift-testing`:

```swift
import Testing
import MurmurCore

@Suite("MurmurInfo")
struct MurmurInfoTests {

    @Test("version is non-empty")
    func versionIsNonEmpty() {
        #expect(!MurmurInfo.version.isEmpty)
    }

    @Test("version matches semver shape")
    func versionMatchesSemver() {
        let pattern = #"^\d+\.\d+\.\d+(-[A-Za-z0-9.-]+)?$"#
        #expect(MurmurInfo.version.range(of: pattern, options: .regularExpression) != nil)
    }

    @Test("bundle identifier is a real reverse-DNS string")
    func bundleIdentifierIsReverseDNS() {
        let parts = MurmurInfo.bundleIdentifier.split(separator: ".")
        #expect(parts.count >= 3)
        #expect(MurmurInfo.bundleIdentifier == MurmurInfo.bundleIdentifier.lowercased())
        #expect(!MurmurInfo.bundleIdentifier.hasPrefix("."))
        #expect(!MurmurInfo.bundleIdentifier.hasSuffix("."))
    }
}
```

Apple-expert tightened the bundle-id test from "contains a dot" to "≥3 dot-separated parts + lowercase" — `"a.b"` previously passed, which would let a regression slide.

Verification:

- `swift build` exits 0
- `swift test` exits 0 with three tests passing
- No warnings under `.swiftLanguageMode(.v6) + ExistentialAny + InternalImportsByDefault`

## .gitignore additions (if missing)

Already covered by existing `.gitignore` — `Packages/`, `.swiftpm/`, `Package.resolved`, `.build/`, `DerivedData/`. No change needed.

## Risks

- **Swift 6 strict concurrency on `print`** — should be a non-issue; `print` is `@Sendable` in Swift 6. Verify locally before merging.
- **Xcode 16 vs CLI swift toolchain divergence** — README claims Xcode 16. SPM via `swift build` from CLI uses whatever is selected by `xcode-select`. The plan only touches CLI; no Xcode project file. If contributors want IDE, they `xed .` and Xcode infers from `Package.swift`. Documented in README already.
- **Bundle identifier choice** — defaulting to `com.murmur.app` for now. Can change before notarization (which is far off). Not load-bearing.

## Acceptance criteria

- [ ] `Package.swift` exists at repo root with the structure above
- [ ] `Sources/Murmur/main.swift` and `Sources/Murmur/MurmurInfo.swift` exist
- [ ] `Tests/MurmurTests/MurmurInfoTests.swift` exists with the three tests above
- [ ] `swift build` succeeds with no warnings
- [ ] `swift test` succeeds, three tests passing
- [ ] `swift run Murmur` prints `Murmur 0.1.0-dev` (or current version) and exits 0
- [ ] No new `.gitignore` entries needed
- [ ] Branch: `feat/swift-package-skeleton`
- [ ] Single squash-merged PR

## Open questions for apple-expert

1. **Strict concurrency on day one** — worth it, or premature for a single-file scaffold? Easier to add later when we have actor boundaries to enforce, harder to retrofit if we don't.
2. **`@testable import Murmur`** on an executable target — works since 5.9, but is there a 2026 gotcha I'm missing? Anything about package access modifier?
3. **macOS 14 floor vs macOS 13** — anything in the README/plan stack (WhisperKit, KeyboardShortcuts) that would let us drop to 13 without pain, or is 14 the right call?
4. **Bundle identifier choice** — `com.murmur.app` placeholder, or should we lock it now to `com.archithrapaka.murmur` / something we won't have to migrate later (notarization, TCC, Sparkle all care about consistency)?
5. **Single-target executable vs library + executable** — keep it as one executable target (current plan), or split into `MurmurCore` library + thin `Murmur` executable now to avoid a refactor later? The split costs nothing now and makes future testing easier.
