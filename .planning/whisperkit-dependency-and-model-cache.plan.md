# Plan — `whisperkit-dependency-and-model-cache`

**Roadmap item:** `- [ ] whisperkit-dependency-and-model-cache` (item 2, milestone v0.1).

**Goal:** Add WhisperKit as an SPM dependency on `MurmurCore`, and ship a small `ModelCache` value type that resolves `~/Library/Application Support/Murmur/Models/` and creates it idempotently. No transcription wiring yet — that's `end-to-end-v0.1`. We are _only_ (a) proving WhisperKit resolves and links, and (b) shipping the path/creation surface every later item depends on.

## What ships

```
murmur/
├── Package.swift                         ← + WhisperKit dependency on MurmurCore target
├── Sources/MurmurCore/
│   ├── MurmurInfo.swift                  ← unchanged
│   └── ModelCache.swift                  ← new: path resolver + ensureExists + presence check
└── Tests/MurmurCoreTests/
    ├── MurmurInfoTests.swift             ← unchanged
    └── ModelCacheTests.swift             ← new: 6 swift-testing tests, all in temp dirs
```

No source change to `Sources/Murmur/main.swift` and no README update — this is library-internal plumbing.

## Package.swift change (sketch)

```swift
// swift-tools-version: 6.0
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
]

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Murmur", targets: ["Murmur"]),
        .library(name: "MurmurCore", targets: ["MurmurCore"]),
    ],
    dependencies: [
        // WhisperKit lives in the argmax-oss-swift umbrella as of v1.0.0
        // (2026-05-01). Old `argmaxinc/WhisperKit` URL 301-redirects here.
        // We pull the `WhisperKit` product specifically — the `ArgmaxOSS`
        // umbrella also includes TTSKit/SpeakerKit which we don't use yet.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.0.0"),
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
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
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

**Note for apple-expert:** I'm pinning the _exact_ current major version that argmaxinc ships (verify in plan review — version below in the Open Questions). `from:` allows minor and patch upgrades, locks major. Want belt-and-suspenders pinning via `Package.resolved` checked in? Or a tighter `.upToNextMinor` constraint?

## ModelCache (sketch)

```swift
import Foundation

/// Resolves on-disk paths for downloaded ML models and ensures the cache
/// directory exists. Pure path/filesystem helper — knows nothing about
/// WhisperKit, model formats, or downloads. Those concerns live in the
/// first-run download item (v0.5).
public struct ModelCache: Sendable {

    /// Root directory for cached models. All model URLs are resolved as
    /// `baseDirectory/<modelName>/`.
    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Production location: `~/Library/Application Support/Murmur/Models/`.
    /// Uses `URL.applicationSupportDirectory` (macOS 13+, we floor at 14).
    public static let `default` = ModelCache(
        baseDirectory: URL.applicationSupportDirectory
            .appending(path: "Murmur", directoryHint: .isDirectory)
            .appending(path: "Models", directoryHint: .isDirectory)
    )

    /// Idempotent: creating an existing directory is a no-op (no error).
    /// Throws if the path can't be created (permission denied, file at
    /// path is not a directory, etc).
    public func ensureExists() throws {
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true
        )
    }

    /// Resolved on-disk URL for a named model. Does not check existence.
    public func url(forModel name: String) -> URL {
        baseDirectory.appending(path: name, directoryHint: .isDirectory)
    }

    /// **Presence check, not validity check.** Returns `true` iff
    /// `<baseDirectory>/<name>/` exists *and is a directory*. Says nothing
    /// about whether the contents form a usable model — partial downloads
    /// or corrupted folders that exist on disk return `true`.
    /// SHA verification against a signed manifest lives in the v0.5
    /// `first-run-model-download-ui` item.
    public func contains(model name: String) -> Bool {
        var isDir: ObjCBool = false
        let path = url(forModel: name).path(percentEncoded: false)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }
}
```

### Design choices, defended

- **`Sendable`** on day one. Crossing actor boundaries is inevitable (`AudioCapture` actor → transcription pipeline → UI). `ModelCache` is a value type wrapping a `URL`, both `Sendable`, so it's a free conformance.
- **`URL.applicationSupportDirectory`**, not `FileManager.default.url(for:in:appropriateFor:create:)`. The former is the modern, non-throwing accessor (macOS 13+). We're on 14 — no reason for the older API.
- **Static `.default` instead of a singleton.** Value type, immutable, no shared mutable state. Tests construct their own with a `baseDirectory` pointing at a per-test temp dir; production code uses `.default`.
- **No SHA verification, no download API.** Both are scoped to v0.5 (`first-run-model-download-ui`). This item is _just_ the location surface.
- **`contains(model:)` requires a directory, not a file.** WhisperKit ships models as `.mlmodelc` directories (CoreML compiled packages). A regular file at the path means partial download or filesystem corruption — deliberately reports `false`.
- **No `init()` with default location.** Forces the caller to be explicit: `ModelCache.default` or `ModelCache(baseDirectory: tempDir)`. Avoids the "did this constructor accidentally hit the user's real Library?" surprise in tests.

## Tests (mandatory — no "trust CI" excuses)

`ModelCacheTests.swift`, swift-testing, six `@Test` cases, all isolated in per-test temp dirs:

```swift
import Foundation
import Testing
import MurmurCore

@Suite("ModelCache")
struct ModelCacheTests {

    /// Helper: fresh empty temp directory for each test, auto-cleaned.
    private func tempDir() -> URL {
        URL.temporaryDirectory.appending(path: "murmur-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test("default cache points at ~/Library/Application Support/Murmur/Models")
    func defaultPathIsApplicationSupportMurmurModels() {
        let tail = Array(ModelCache.default.baseDirectory.pathComponents.suffix(4))
        #expect(tail == ["Library", "Application Support", "Murmur", "Models"])
    }

    @Test("ensureExists creates the directory")
    func ensureExistsCreatesDirectory() throws {
        let cache = ModelCache(baseDirectory: tempDir())
        #expect(!FileManager.default.fileExists(atPath: cache.baseDirectory.path()))
        try cache.ensureExists()
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: cache.baseDirectory.path(percentEncoded: false), isDirectory: &isDir))
        #expect(isDir.boolValue)
        try? FileManager.default.removeItem(at: cache.baseDirectory)
    }

    @Test("ensureExists is idempotent")
    func ensureExistsIsIdempotent() throws {
        let cache = ModelCache(baseDirectory: tempDir())
        try cache.ensureExists()
        try cache.ensureExists()  // must not throw
        try? FileManager.default.removeItem(at: cache.baseDirectory)
    }

    @Test("url(forModel:) composes baseDirectory + name")
    func urlForModelComposesCorrectly() {
        let cache = ModelCache(baseDirectory: URL(filePath: "/tmp/x"))
        let resolved = cache.url(forModel: "whisper-large-v3-turbo")
        #expect(resolved.path(percentEncoded: false) == "/tmp/x/whisper-large-v3-turbo")
    }

    @Test("contains(model:) is false for missing model")
    func containsIsFalseWhenAbsent() throws {
        let cache = ModelCache(baseDirectory: tempDir())
        try cache.ensureExists()
        #expect(!cache.contains(model: "nonexistent"))
        try? FileManager.default.removeItem(at: cache.baseDirectory)
    }

    @Test("contains(model:) is true after creating the model directory")
    func containsIsTrueAfterCreation() throws {
        let cache = ModelCache(baseDirectory: tempDir())
        try cache.ensureExists()
        let modelURL = cache.url(forModel: "whisper-large-v3-turbo")
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: false)
        #expect(cache.contains(model: "whisper-large-v3-turbo"))
        try? FileManager.default.removeItem(at: cache.baseDirectory)
    }
}
```

Verification:

- `swift build` succeeds (with WhisperKit pulled, this is the WhisperKit-link smoke test)
- `swift test` runs the existing 3 + new 6 = 9 tests, all passing
- No new warnings under our strict settings
- Tests do **not** touch `~/Library/Application Support/Murmur/`. Verified by inspection of the test code — every test that creates anything uses `tempDir()`.

## Risks

- **WhisperKit transitive dependency surface.** Could pull in heavy/awkward deps (a separate ML graph framework, etc.) that bloat build time or conflict later. Mitigation: review `Package.resolved` after `swift build`, flag anything surprising in the PR.
- **WhisperKit minimum platform.** If they bumped to macOS 15 or 26 in a recent release, the `.macOS(.v14)` floor breaks. Mitigation: check release notes; if they bumped, pin to the last 14-compatible version with a comment.
- **`URL.applicationSupportDirectory` returns a URL even if the directory doesn't exist.** `ensureExists()` is the actual guarantee. Documented above; the path test asserts the _string_, not directory existence.
- **`contains(model:)` requires a directory.** If someone partially downloads a model and lands a file at that path, this returns `false` — desired behavior, but worth documenting. Already commented in code.

## Acceptance criteria

- [ ] `Package.swift` adds WhisperKit `from: "<pinned version>"` as a dependency on `MurmurCore`
- [ ] `Sources/MurmurCore/ModelCache.swift` exists with the four-method API above
- [ ] `Tests/MurmurCoreTests/ModelCacheTests.swift` exists with 6 swift-testing tests
- [ ] `swift build` exits 0 with WhisperKit linked (proves the dependency resolves)
- [ ] `swift test` exits 0 with **9** tests passing (3 existing + 6 new)
- [ ] No tests touch the user's real `~/Library/Application Support/`
- [ ] Branch: `feat/whisperkit-dependency-and-model-cache`
- [ ] Single squash-merged PR

## Apple-expert revisions applied

1. **WhisperKit URL** changed to `argmaxinc/argmax-oss-swift` v1.0.0 (released 2026-05-01) — product `WhisperKit`, package name `argmax-oss-swift`. Verified live via `gh repo view`.
2. **`Equatable` dropped** from `ModelCache` — premature API surface, nothing in the architecture plan needs it. Re-add when a caller does.
3. **Path test** uses `pathComponents.suffix(4)` tail-match, not `hasSuffix(String)` — robust to trailing slashes and any future Foundation behavior change.
4. **`Package.resolved` will be committed** — Murmur is a distributed app, reproducibility wins over library convention. `.gitignore` updated if necessary (currently does not exclude `Package.resolved`, so it'll be tracked by default).
5. **`contains(model:)` documented as a presence check, not a validity check.** SHA verification lives in v0.5.

## Open questions for apple-expert (resolved in review)

1. **Pinned WhisperKit version.** What's the current stable release of `argmaxinc/WhisperKit` in May 2026, and is it macOS-14-compatible? `from: "0.10.0"` is a placeholder — recommend the version I should actually pin.
2. **`Package.resolved` checked in.** SPM tradition is to commit it for executable/app projects (reproducible builds across contributors), skip it for libraries. Murmur is _both_. Recommend?
3. **`URL.applicationSupportDirectory` vs `FileManager.default.url(for:...)`** — modern accessor vs throwing API. Anything wrong with the modern one I'm missing?
4. **Sandboxed concerns later.** Architecture plan is non-sandboxed. If we ever add sandbox in a fork or iOS port, `~/Library/Application Support/Murmur/` becomes container-relative. Should `ModelCache.default` auto-detect, or is that a v2 problem?
5. **WhisperKit's own model cache.** WhisperKit ships its own `WhisperKitConfig.modelFolder` mechanism. Are we duplicating? Should `ModelCache` _wrap_ WhisperKit's resolver, or stay independent and pass an explicit `modelFolder` URL into WhisperKit later? I'm leaning independent (WhisperKit defaults to `~/Documents/huggingface/...` per their docs, which is wrong for our distribution model — we want our own dir).
6. **Transitive Foundation imports.** Per the previous PR's lesson — `ModelCache.swift` legitimately uses `URL`, `FileManager`, `ObjCBool`, all Foundation. `import Foundation` declared. But should the `public` API of `ModelCache` (which exposes `URL`) require `public import Foundation` to re-export `URL` to consumers under `InternalImportsByDefault`? Or do consumers always already have Foundation in scope from their own use of stdlib types?
7. **`ObjCBool` use.** `FileManager.fileExists(atPath:isDirectory:)` requires it. Is the modern non-Objc-bridge alternative anywhere, or is this still the right idiom in Swift 6?
