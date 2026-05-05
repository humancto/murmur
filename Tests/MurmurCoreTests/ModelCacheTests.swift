import Foundation
import Testing
import MurmurCore

@Suite("ModelCache")
struct ModelCacheTests {

    /// Fresh empty temp directory for each test. Caller must clean up via `defer`.
    private func tempDir() -> URL {
        URL.temporaryDirectory.appending(
            path: "murmur-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    }

    @Test("production cache points at ~/Library/Application Support/Murmur/Models")
    func productionPathIsApplicationSupportMurmurModels() {
        let tail = Array(ModelCache.production.baseDirectory.pathComponents.suffix(4))
        #expect(tail == ["Library", "Application Support", "Murmur", "Models"])
    }

    @Test("ensureExists creates the directory")
    func ensureExistsCreatesDirectory() throws {
        let cache = ModelCache(baseDirectory: tempDir())
        defer { try? FileManager.default.removeItem(at: cache.baseDirectory) }

        let path = cache.baseDirectory.path(percentEncoded: false)
        #expect(!FileManager.default.fileExists(atPath: path))

        try cache.ensureExists()

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        #expect(exists)
        #expect(isDir.boolValue)
    }

    @Test("ensureExists is idempotent — second call does not throw")
    func ensureExistsIsIdempotent() throws {
        let cache = ModelCache(baseDirectory: tempDir())
        defer { try? FileManager.default.removeItem(at: cache.baseDirectory) }

        try cache.ensureExists()
        try cache.ensureExists()  // must not throw
    }

    @Test("url(forModel:) composes baseDirectory + name")
    func urlForModelComposesCorrectly() {
        let cache = ModelCache(baseDirectory: URL(filePath: "/tmp/x"))
        let resolved = cache.url(forModel: "whisper-large-v3-turbo")
        let tail = Array(resolved.pathComponents.suffix(3))
        #expect(tail == ["tmp", "x", "whisper-large-v3-turbo"])
    }

    @Test("contains(model:) is false for missing model")
    func containsIsFalseWhenAbsent() throws {
        let cache = ModelCache(baseDirectory: tempDir())
        defer { try? FileManager.default.removeItem(at: cache.baseDirectory) }

        try cache.ensureExists()
        #expect(!cache.contains(model: "nonexistent"))
    }

    @Test("contains(model:) is true after creating the model directory")
    func containsIsTrueAfterCreation() throws {
        let cache = ModelCache(baseDirectory: tempDir())
        defer { try? FileManager.default.removeItem(at: cache.baseDirectory) }

        try cache.ensureExists()
        let modelURL = cache.url(forModel: "whisper-large-v3-turbo")
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: false)

        #expect(cache.contains(model: "whisper-large-v3-turbo"))
    }
}
