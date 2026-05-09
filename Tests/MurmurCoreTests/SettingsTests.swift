import Foundation
import Testing
import MurmurCore

@Suite("Settings")
struct SettingsTests {

    /// Per-test isolated UserDefaults suite. Caller must clean up via defer.
    private func tempSuite() -> (suite: UserDefaults, name: String) {
        let name = "murmur-tests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: name)!
        return (suite, name)
    }

    @Test("default Settings has empty vocabulary, audio cues off, 60s cap, cleanup off, onboarding incomplete")
    func defaultSettingsAreSensible() {
        let s = Settings()
        #expect(s.vocabulary.isEmpty)
        #expect(s.playAudioCues == false)
        #expect(s.captureMaxDurationSec == 60)
        #expect(s.didCompleteOnboarding == false)
        #expect(s.llmCleanupEnabled == false)
    }

    @Test("decoding payload missing llmCleanupEnabled defaults to false")
    func decodeMissingLLMFieldFallsBackToDefault() throws {
        // Simulate a v0.1-era app build's persisted JSON, before
        // llmCleanupEnabled was added.
        let v01era = Data(#"{"vocabulary":["foo"],"playAudioCues":true,"captureMaxDurationSec":45,"didCompleteOnboarding":true}"#.utf8)
        let decoded = try JSONDecoder().decode(Settings.self, from: v01era)
        #expect(decoded.vocabulary == ["foo"])
        #expect(decoded.playAudioCues == true)
        #expect(decoded.captureMaxDurationSec == 45)
        #expect(decoded.didCompleteOnboarding == true)
        #expect(decoded.llmCleanupEnabled == false)
    }

    @Test("Codable round-trip preserves equality across all fields")
    func codableRoundTrip() throws {
        let original = Settings(
            vocabulary: ["Archith", "WhisperKit", "ANE"],
            playAudioCues: true,
            captureMaxDurationSec: 120,
            didCompleteOnboarding: true,
            llmCleanupEnabled: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded == original)
    }

    @Test("Codable decodes older payloads with missing fields using defaults")
    func decodeMissingFieldsFallsBackToDefaults() throws {
        // Simulate an older app version that only persisted `vocabulary`.
        let partial = Data(#"{"vocabulary":["foo","bar"]}"#.utf8)
        let decoded = try JSONDecoder().decode(Settings.self, from: partial)
        #expect(decoded.vocabulary == ["foo", "bar"])
        #expect(decoded.playAudioCues == false)
        #expect(decoded.captureMaxDurationSec == 60)
    }

    @Test("SettingsStore returns defaults when no data persisted")
    func storeReturnsDefaultsOnMissingData() {
        let (suite, name) = tempSuite()
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let store = SettingsStore(suite: suite)
        #expect(store.load() == Settings())
    }

    @Test("SettingsStore round-trips via UserDefaults suite")
    func storeRoundTrips() throws {
        let (suite, name) = tempSuite()
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let store = SettingsStore(suite: suite)
        let payload = Settings(vocabulary: ["foo", "bar"], playAudioCues: true, captureMaxDurationSec: 30)
        try store.save(payload)
        #expect(store.load() == payload)
    }

    @Test("SettingsStore returns defaults on malformed JSON")
    func storeFallsBackOnBadData() {
        let (suite, name) = tempSuite()
        defer { UserDefaults().removePersistentDomain(forName: name) }
        suite.set(Data("not valid json".utf8), forKey: "dev.murmur.settings.v1")
        let store = SettingsStore(suite: suite)
        #expect(store.load() == Settings())
    }

    @Test("SettingsStore.clear removes the persisted entry")
    func storeClear() throws {
        let (suite, name) = tempSuite()
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let store = SettingsStore(suite: suite)
        try store.save(Settings(vocabulary: ["x"]))
        store.clear()
        #expect(store.load() == Settings())
    }
}
