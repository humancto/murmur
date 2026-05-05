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
        let id = MurmurInfo.bundleIdentifier
        let parts = id.split(separator: ".")
        #expect(parts.count >= 3, "bundle id must have ≥3 reverse-DNS parts")
        #expect(id == id.lowercased(), "bundle id must be lowercase")
        #expect(!id.hasPrefix("."))
        #expect(!id.hasSuffix("."))
    }
}
