public import Foundation

/// Resolves on-disk paths for cached ML models and ensures the cache
/// directory exists. Pure path/filesystem helper — knows nothing about
/// WhisperKit, model formats, or downloads. Those concerns live in the
/// first-run download item (v0.5).
public struct ModelCache: Sendable {

    /// Root directory for cached models. Model URLs are resolved as
    /// `<baseDirectory>/<modelName>/`.
    public let baseDirectory: URL

    public init(baseDirectory: URL) {
        self.baseDirectory = baseDirectory
    }

    /// Production location: `~/Library/Application Support/Murmur/Models/`.
    /// Uses `URL.applicationSupportDirectory` (macOS 13+, we floor at 14).
    public static let production = ModelCache(
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
    /// or corrupted folders that exist on disk still return `true`.
    /// SHA verification against a signed manifest lives in the v0.5
    /// `first-run-model-download-ui` item.
    public func contains(model name: String) -> Bool {
        var isDir: ObjCBool = false
        let path = url(forModel: name).path(percentEncoded: false)
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }
}
