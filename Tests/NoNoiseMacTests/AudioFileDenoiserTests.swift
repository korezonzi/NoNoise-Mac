import AVFoundation
import XCTest
@testable import Core

final class AudioFileDenoiserTests: XCTestCase {
    func testRejectsMissingInputFile() async {
        let denoiser = AudioFileDenoiser()
        let options = AudioDenoiseOptions(inputPath: "/tmp/does-not-exist.wav", outputPath: "/tmp/out.wav")
        await XCTAssertThrowsErrorAsync(try await denoiser.denoise(options))
    }

    func testRejectsExistingOutputWithoutOverwrite() async throws {
        let temp = FileManager.default.temporaryDirectory
        let input = temp.appendingPathComponent("nonoise-empty-input.wav")
        let output = temp.appendingPathComponent("nonoise-existing-output.wav")
        FileManager.default.createFile(atPath: input.path, contents: Data())
        FileManager.default.createFile(atPath: output.path, contents: Data())
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }

        let denoiser = AudioFileDenoiser()
        let options = AudioDenoiseOptions(inputPath: input.path, outputPath: output.path)
        await XCTAssertThrowsErrorAsync(try await denoiser.denoise(options))
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // Expected.
    }
}
