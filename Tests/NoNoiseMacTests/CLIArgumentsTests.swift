import XCTest
@testable import Core

final class CLIArgumentsTests: XCTestCase {
    func testParsesLiveDeviceMode() throws {
        let mode = try CLIArguments.parse(["NoNoiseMacCLI", "--in", "Built-in", "--out", "BlackHole", "--gain", "1.5"])
        XCTAssertEqual(mode, .live(input: "Built-in", output: "BlackHole", gain: 1.5))
    }

    func testParsesActionMode() throws {
        let mode = try CLIArguments.parse(["NoNoiseMacCLI", "--action", "toggle"])
        XCTAssertEqual(mode, .action("toggle"))
    }

    func testParsesAudioDenoiseMode() throws {
        let mode = try CLIArguments.parse([
            "NoNoiseMacCLI",
            "--denoise", "/tmp/noisy.wav",
            "--output", "/tmp/clean.wav",
            "--preset", "medium",
            "--gain", "1.25",
            "--strength", "0.8",
            "--attenuation-db", "24",
            "--overwrite"
        ])
        XCTAssertEqual(mode, .denoise(AudioDenoiseOptions(
            inputPath: "/tmp/noisy.wav",
            outputPath: "/tmp/clean.wav",
            preset: .medium,
            gain: 1.25,
            strength: 0.8,
            attenuationDb: 24,
            shouldOverwrite: true
        )))
    }

    /// The legacy preset name "podcast" is still accepted and resolves to its migration
    /// target `.medium` — same DSP defaults as the current name would produce.
    func testParsesLegacyPresetNameAsAlias() throws {
        let mode = try CLIArguments.parse([
            "NoNoiseMacCLI",
            "--denoise", "/tmp/noisy.wav",
            "--output", "/tmp/clean.wav",
            "--preset", "podcast"
        ])
        XCTAssertEqual(mode, .denoise(AudioDenoiseOptions(
            inputPath: "/tmp/noisy.wav",
            outputPath: "/tmp/clean.wav",
            preset: .medium,
            gain: 1.0,
            strength: 0.88,
            attenuationDb: 32.0,
            shouldOverwrite: false
        )))
    }

    func testPresetAppliesDSPDefaultsWhenKnobsAreNotExplicit() throws {
        let mode = try CLIArguments.parse([
            "NoNoiseMacCLI",
            "--denoise", "/tmp/noisy.wav",
            "--output", "/tmp/clean.wav",
            "--preset", "medium"
        ])
        XCTAssertEqual(mode, .denoise(AudioDenoiseOptions(
            inputPath: "/tmp/noisy.wav",
            outputPath: "/tmp/clean.wav",
            preset: .medium,
            gain: 1.0,
            strength: 0.88,
            attenuationDb: 32.0,
            shouldOverwrite: false
        )))
    }

    func testExplicitKnobsOverridePresetDefaults() throws {
        let mode = try CLIArguments.parse([
            "NoNoiseMacCLI",
            "--denoise", "/tmp/noisy.wav",
            "--output", "/tmp/clean.wav",
            "--preset", "medium",
            "--attenuation-db", "18"
        ])
        if case .denoise(let options) = mode {
            XCTAssertEqual(options.attenuationDb, 18)
        } else {
            XCTFail("expected denoise mode")
        }
    }

    func testMixedActionAndDenoiseModeFails() {
        XCTAssertThrowsError(try CLIArguments.parse([
            "NoNoiseMacCLI", "--action", "toggle", "--denoise", "/tmp/noisy.wav", "--output", "/tmp/clean.wav"
        ]))
    }

    func testDenoiseRequiresOutput() {
        XCTAssertThrowsError(try CLIArguments.parse(["NoNoiseMacCLI", "--denoise", "/tmp/noisy.wav"])) { error in
            XCTAssertEqual(error as? CLIArguments.ParseError, .missingValue("--output"))
        }
    }

    func testOutputWithoutDenoiseFails() {
        XCTAssertThrowsError(try CLIArguments.parse(["NoNoiseMacCLI", "--output", "/tmp/clean.wav"])) { error in
            XCTAssertEqual(error as? CLIArguments.ParseError, .missingValue("--denoise"))
        }
    }

    func testUnknownPresetFails() {
        XCTAssertThrowsError(try CLIArguments.parse([
            "NoNoiseMacCLI", "--denoise", "/tmp/noisy.wav", "--output", "/tmp/clean.wav", "--preset", "radio"
        ]))
    }

    // MARK: - --aec-spike

    func testParsesAECSpikeModeWithDefaults() throws {
        let mode = try CLIArguments.parse(["NoNoiseMacCLI", "--aec-spike", "self"])
        XCTAssertEqual(mode, .aecSpike(AECSpikeOptions(scenario: "self")))
    }

    func testParsesAECSpikeModeWithAllFlags() throws {
        let mode = try CLIArguments.parse([
            "NoNoiseMacCLI",
            "--aec-spike", "all",
            "--spike-out", "/tmp/spike-output",
            "--spike-duration", "5.5",
            "--spike-input", "MacBook Pro Microphone"
        ])
        XCTAssertEqual(mode, .aecSpike(AECSpikeOptions(
            scenario: "all",
            outputDir: "/tmp/spike-output",
            durationSec: 5.5,
            inputSelection: "MacBook Pro Microphone"
        )))
    }

    func testAECSpikeScenarioIsCaseInsensitive() throws {
        let mode = try CLIArguments.parse(["NoNoiseMacCLI", "--aec-spike", "SELF"])
        XCTAssertEqual(mode, .aecSpike(AECSpikeOptions(scenario: "self")))
    }

    func testUnknownAECSpikeScenarioFails() {
        XCTAssertThrowsError(try CLIArguments.parse(["NoNoiseMacCLI", "--aec-spike", "bogus"])) { error in
            XCTAssertEqual(error as? CLIArguments.ParseError, .invalidSpikeScenario("bogus"))
        }
    }

    func testMixedAECSpikeAndDenoiseModeFails() {
        XCTAssertThrowsError(try CLIArguments.parse([
            "NoNoiseMacCLI", "--aec-spike", "self", "--denoise", "/tmp/noisy.wav", "--output", "/tmp/clean.wav"
        ])) { error in
            XCTAssertEqual(error as? CLIArguments.ParseError, .mixedModes)
        }
    }

    func testMixedAECSpikeAndLiveModeFails() {
        XCTAssertThrowsError(try CLIArguments.parse([
            "NoNoiseMacCLI", "--aec-spike", "self", "--in", "Built-in", "--out", "BlackHole"
        ])) { error in
            XCTAssertEqual(error as? CLIArguments.ParseError, .mixedModes)
        }
    }

    func testAECSpikeMissingDurationValueFails() {
        XCTAssertThrowsError(try CLIArguments.parse([
            "NoNoiseMacCLI", "--aec-spike", "self", "--spike-duration"
        ])) { error in
            XCTAssertEqual(error as? CLIArguments.ParseError, .missingValue("--spike-duration"))
        }
    }

    /// `Double("nan")`/`Double("inf")` both parse successfully in Swift, so a naive `Float(...)`
    /// parse alone would let NaN/infinite/out-of-range durations through the CLI boundary and only
    /// crash later (`Int(durationSec * ...)`/`UInt64(durationSec * 1_000_000_000)` traps at
    /// runtime) deep inside `VoiceIOSpikeRunner`. All of these must be rejected right here instead.
    func testAECSpikeDurationRejectsInvalidValues() {
        let invalidValues = ["nan", "inf", "-5", "0", "601"]
        for value in invalidValues {
            XCTAssertThrowsError(try CLIArguments.parse([
                "NoNoiseMacCLI", "--aec-spike", "self", "--spike-duration", value
            ]), "value: \(value)") { error in
                XCTAssertEqual(error as? CLIArguments.ParseError, .invalidFloat("--spike-duration", value), "value: \(value)")
            }
        }
    }

    func testMixedAECSpikeAndActionModeFails() {
        XCTAssertThrowsError(try CLIArguments.parse([
            "NoNoiseMacCLI", "--aec-spike", "self", "--action", "toggle"
        ])) { error in
            XCTAssertEqual(error as? CLIArguments.ParseError, .mixedModes)
        }
    }

    /// `AECSpikeOptions.validScenarios` is DERIVED from `AECSpikeScenario.allCases` — this guards
    /// against the two ever drifting apart again (e.g. a new case added to one but not the other).
    func testAECSpikeScenarioAllCasesMatchesValidScenarios() {
        let fromEnum = Set(AECSpikeScenario.allCases.map { $0.rawValue })
        XCTAssertEqual(fromEnum, AECSpikeOptions.validScenarios)
        XCTAssertEqual(fromEnum.count, AECSpikeScenario.allCases.count, "raw values must be unique")
    }
}
