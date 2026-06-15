import AVFoundation
import Foundation

public final class AudioFileDenoiser {
    public enum DenoiseError: Error, Equatable, CustomStringConvertible {
        case inputFileMissing(String)
        case outputExists(String)
        case modelNotReady

        public var description: String {
            switch self {
            case .inputFileMissing(let path): return "Input file does not exist: \(path)"
            case .outputExists(let path): return "Output file already exists: \(path). Pass --overwrite to replace it."
            case .modelNotReady: return "Noise cancellation model did not finish loading."
            }
        }
    }

    public init() {}

    public func denoise(_ options: AudioDenoiseOptions,
                        progress: ((Double) -> Void)? = nil) async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: options.inputPath) else {
            throw DenoiseError.inputFileMissing(options.inputPath)
        }
        if fileManager.fileExists(atPath: options.outputPath), !options.shouldOverwrite {
            throw DenoiseError.outputExists(options.outputPath)
        }
        _ = progress
        throw DenoiseError.modelNotReady
    }
}
