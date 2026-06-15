import XCTest
@testable import Core

final class VoiceProfileTests: XCTestCase {

    // MARK: - Round-trip encoding

    /// A profile must encode to JSON and decode back without data loss.
    func testProfileRoundTrips() throws {
        let profile = VoiceProfile(
            id: UUID(),
            name: "Solo Narration",
            preset: .podcast,
            suppressionStrength: 0.85,
            attenuationLimitDb: 24.0,
            outputGainValue: 1.2,
            voicePolishEnabled: true,
            clarityLevel: .medium
        )
        let data = try VoiceProfile.encoder.encode(profile)
        let decoded = try VoiceProfile.decoder.decode(VoiceProfile.self, from: data)
        XCTAssertEqual(decoded.id, profile.id)
        XCTAssertEqual(decoded.name, profile.name)
        XCTAssertEqual(decoded.preset, profile.preset)
        XCTAssertEqual(decoded.suppressionStrength, profile.suppressionStrength, accuracy: 1e-6)
        XCTAssertEqual(decoded.attenuationLimitDb, profile.attenuationLimitDb, accuracy: 1e-6)
        XCTAssertEqual(decoded.outputGainValue, profile.outputGainValue, accuracy: 1e-6)
        XCTAssertEqual(decoded.voicePolishEnabled, profile.voicePolishEnabled)
        XCTAssertEqual(decoded.clarityLevel, profile.clarityLevel)
        XCTAssertEqual(decoded.version, 1)
    }

    // MARK: - Extensibility: unknown fields are tolerated (schema forward-compatibility)

    /// A JSON payload with unknown fields (e.g. from a future plan's additions) must decode
    /// without error — the decoder silently ignores unknown keys.
    func testUnknownFieldsAreIgnored() throws {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "version": 1,
          "name": "Test",
          "preset": "podcast",
          "suppression_strength": 1.0,
          "attenuation_limit_db": 24.0,
          "output_gain_value": 1.0,
          "voice_polish_enabled": true,
          "clarity_level": "off",
          "lufs_target": -16.0,
          "normalization_enabled": true,
          "deplosive_level": 0.5,
          "declick_level": 0.3
        }
        """.data(using: .utf8)!
        let decoded = try VoiceProfile.decoder.decode(VoiceProfile.self, from: json)
        XCTAssertEqual(decoded.name, "Test")
        XCTAssertEqual(decoded.preset, .podcast)
        // Future optional fields should not cause decoding failure.
        // (They are nil since VoiceProfile v1 doesn't declare them yet.)
    }

    // MARK: - Extensibility: missing optional future fields default gracefully

    /// A JSON payload WITHOUT optional fields (i.e. produced by an older version)
    /// must decode cleanly — missing optional fields default to nil.
    func testMissingOptionalFieldsDefaultToNil() throws {
        // This represents a minimal v1 payload with no future extension fields.
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000002",
          "version": 1,
          "name": "Minimal",
          "preset": "meeting",
          "suppression_strength": 1.0,
          "attenuation_limit_db": 100.0,
          "output_gain_value": 1.0,
          "voice_polish_enabled": false,
          "clarity_level": "off"
        }
        """.data(using: .utf8)!
        let decoded = try VoiceProfile.decoder.decode(VoiceProfile.self, from: json)
        XCTAssertEqual(decoded.name, "Minimal")
        XCTAssertEqual(decoded.preset, .meeting)
        // Confirm decoding succeeds cleanly with no future fields present.
        XCTAssertEqual(decoded.version, 1)
    }

    // MARK: - Version field is always present

    func testEncodedPayloadContainsVersionField() throws {
        let profile = VoiceProfile.makeDefault(name: "Test")
        let data = try VoiceProfile.encoder.encode(profile)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["version"], "encoded payload must always include a version field")
    }

    // MARK: - Default factory

    /// makeDefault produces a valid profile from the Meeting preset defaults.
    func testMakeDefaultIsValid() {
        let p = VoiceProfile.makeDefault(name: "New Profile")
        XCTAssertEqual(p.name, "New Profile")
        XCTAssertEqual(p.preset, .meeting)
        XCTAssertEqual(p.suppressionStrength, 1.0, accuracy: 1e-6)
        XCTAssertEqual(p.attenuationLimitDb, VoicePreset.maxAttenuationDb, accuracy: 1e-6)
        XCTAssertEqual(p.outputGainValue, 1.0, accuracy: 1e-6)
        XCTAssertFalse(p.voicePolishEnabled == false && p.clarityLevel == .off, "defaults should be sane")
    }

    // MARK: - Unique IDs

    func testProfileIDsAreUnique() {
        let a = VoiceProfile.makeDefault(name: "A")
        let b = VoiceProfile.makeDefault(name: "B")
        XCTAssertNotEqual(a.id, b.id)
    }
}
