import XCTest
import CTapRing
@testable import Core

/// Host unit tests for `VoiceIOEngine.prepareCleanupRender` — the drain/latency-trim/silence-bypass
/// step shared by the `.ownEngine` render closures (`IncomingCleanupEngine`/`SpeakerCleanupEngine`)
/// and the `.external` VPIO-hook path. Exercises everything up to (but never including) the actual
/// `DeepFilterNetDSP.process` call, per the approved plan ("DFN 自体はモックしない — DFN 呼び出しを
/// 含まない前段 static に切る"): a real `DeepFilterNetDSP()` instance is constructed (matching
/// `DeepFilterNetDSPTests`' established pattern of not waiting on the async model load) purely to
/// provide the `Unmanaged` reference and its plain `aiActivity` property — no CoreML call happens in
/// any test here.
final class VoiceIOEngineRenderTests: XCTestCase {

    private func makeHook(ring: TapAudioRing, dsp: DeepFilterNetDSP, levelBox: UnsafeMutablePointer<Float>,
                          latencyTargetFrames: Int = 2_400,
                          silenceRunCountBox: UnsafeMutablePointer<Int32>? = nil,
                          silenceRMSThreshold: Float = 0, silenceHoldBuffers: Int32 = 0) -> CleanupRenderHook {
        CleanupRenderHook(ringPtr: ring.cRing, dsp: .passUnretained(dsp), levelPtr: levelBox,
                         latencyTargetFrames: latencyTargetFrames,
                         silenceRunCountBox: silenceRunCountBox,
                         silenceRMSThreshold: silenceRMSThreshold, silenceHoldBuffers: silenceHoldBuffers)
    }

    private func write(_ ring: TapAudioRing, _ values: [Float]) {
        values.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: values.count) }
    }

    // MARK: - Drain (Incoming-style: no silence bypass)

    func testDrainsExactlyCountFramesAndReportsShouldRunDFN() {
        let ring = TapAudioRing(capacityFrames: 64)
        write(ring, [1, 2, 3, 4])
        let dsp = DeepFilterNetDSP()
        let levelBox = UnsafeMutablePointer<Float>.allocate(capacity: 1); levelBox.initialize(to: -1)
        defer { levelBox.deallocate() }
        let hook = makeHook(ring: ring, dsp: dsp, levelBox: levelBox)

        var data: [Float] = [0, 0, 0, 0]
        let shouldRunDFN = data.withUnsafeMutableBufferPointer {
            VoiceIOEngine.prepareCleanupRender(hook: hook, data: $0.baseAddress!, count: 4)
        }

        XCTAssertTrue(shouldRunDFN)
        XCTAssertEqual(data, [1, 2, 3, 4])
        XCTAssertGreaterThan(levelBox.pointee, 0)   // RMS of a non-zero buffer is > 0
        XCTAssertEqual(ring.availableToRead, 0)
    }

    func testUnderflowFillsSilenceZeroesLevelAndSkipsDFN() {
        let ring = TapAudioRing(capacityFrames: 64)
        write(ring, [9, 8])   // only 2 available, requesting 4 below
        let dsp = DeepFilterNetDSP()
        let levelBox = UnsafeMutablePointer<Float>.allocate(capacity: 1); levelBox.initialize(to: 0.5)
        defer { levelBox.deallocate() }
        let hook = makeHook(ring: ring, dsp: dsp, levelBox: levelBox)

        var data: [Float] = [-1, -1, -1, -1]
        let shouldRunDFN = data.withUnsafeMutableBufferPointer {
            VoiceIOEngine.prepareCleanupRender(hook: hook, data: $0.baseAddress!, count: 4)
        }

        XCTAssertFalse(shouldRunDFN)
        XCTAssertEqual(data, [0, 0, 0, 0])
        XCTAssertEqual(levelBox.pointee, 0)
        XCTAssertEqual(ring.availableToRead, 2)   // underflow leaves the ring untouched
    }

    func testLatencyTrimDropsBacklogBeyondTarget() {
        let ring = TapAudioRing(capacityFrames: 64)
        // 20 frames buffered, latency target 4, requesting 4 → trim should drop (20 - 4) = 16 oldest
        // frames, leaving exactly the newest 4 ([17, 18, 19, 20]) to read.
        write(ring, Array((1...20).map { Float($0) }))
        let dsp = DeepFilterNetDSP()
        let levelBox = UnsafeMutablePointer<Float>.allocate(capacity: 1); levelBox.initialize(to: 0)
        defer { levelBox.deallocate() }
        let hook = makeHook(ring: ring, dsp: dsp, levelBox: levelBox, latencyTargetFrames: 4)

        var data: [Float] = [0, 0, 0, 0]
        let shouldRunDFN = data.withUnsafeMutableBufferPointer {
            VoiceIOEngine.prepareCleanupRender(hook: hook, data: $0.baseAddress!, count: 4)
        }

        XCTAssertTrue(shouldRunDFN)
        XCTAssertEqual(data, [17, 18, 19, 20])
        XCTAssertEqual(ring.availableToRead, 0)
    }

    // MARK: - Silence bypass (Speaker-style: silenceRunCountBox present)

    func testSilenceBypassSkipsDFNOnlyAfterHoldBuffersExceeded() {
        let ring = TapAudioRing(capacityFrames: 64)
        let dsp = DeepFilterNetDSP()
        let levelBox = UnsafeMutablePointer<Float>.allocate(capacity: 1); levelBox.initialize(to: 0)
        defer { levelBox.deallocate() }
        let silenceBox = UnsafeMutablePointer<Int32>.allocate(capacity: 1); silenceBox.pointee = 0
        defer { silenceBox.deallocate() }
        let hook = makeHook(ring: ring, dsp: dsp, levelBox: levelBox,
                           silenceRunCountBox: silenceBox, silenceRMSThreshold: 0.1, silenceHoldBuffers: 2)

        // Three consecutive near-silent buffers: hold=2 means the FIRST two still run DFN (count
        // reaches 1, then 2 — neither is `> holdBuffers`), the THIRD (count reaches 3 > 2) bypasses.
        let quiet: [Float] = [0.001, 0.001, 0.001, 0.001]
        for expectedRunsDFN in [true, true, false] {
            write(ring, quiet)
            var data = quiet
            let shouldRunDFN = data.withUnsafeMutableBufferPointer {
                VoiceIOEngine.prepareCleanupRender(hook: hook, data: $0.baseAddress!, count: 4)
            }
            XCTAssertEqual(shouldRunDFN, expectedRunsDFN)
        }
    }

    func testSilenceRunResetsOnceSignalReturnsAboveThreshold() {
        let ring = TapAudioRing(capacityFrames: 64)
        let dsp = DeepFilterNetDSP()
        let levelBox = UnsafeMutablePointer<Float>.allocate(capacity: 1); levelBox.initialize(to: 0)
        defer { levelBox.deallocate() }
        let silenceBox = UnsafeMutablePointer<Int32>.allocate(capacity: 1); silenceBox.pointee = 5
        defer { silenceBox.deallocate() }
        let hook = makeHook(ring: ring, dsp: dsp, levelBox: levelBox,
                           silenceRunCountBox: silenceBox, silenceRMSThreshold: 0.1, silenceHoldBuffers: 2)

        // silenceBox already past holdBuffers (5 > 2), but a LOUD buffer should reset the counter and
        // run DFN this frame (mirrors SpeakerCleanupEngine's original "resumes DFN immediately" note).
        let loud: [Float] = [0.9, -0.9, 0.9, -0.9]
        write(ring, loud)
        var data = loud
        let shouldRunDFN = data.withUnsafeMutableBufferPointer {
            VoiceIOEngine.prepareCleanupRender(hook: hook, data: $0.baseAddress!, count: 4)
        }
        XCTAssertTrue(shouldRunDFN)
        XCTAssertEqual(silenceBox.pointee, 0)
    }

    func testIncomingStyleHookNeverBypassesRegardlessOfSilence() {
        // No silenceRunCountBox (Incoming Cleanup's shape) — even a dead-silent buffer must still run
        // DFN; only ring underflow may skip it.
        let ring = TapAudioRing(capacityFrames: 64)
        write(ring, [0, 0, 0, 0])
        let dsp = DeepFilterNetDSP()
        let levelBox = UnsafeMutablePointer<Float>.allocate(capacity: 1); levelBox.initialize(to: -1)
        defer { levelBox.deallocate() }
        let hook = makeHook(ring: ring, dsp: dsp, levelBox: levelBox)

        var data: [Float] = [0, 0, 0, 0]
        let shouldRunDFN = data.withUnsafeMutableBufferPointer {
            VoiceIOEngine.prepareCleanupRender(hook: hook, data: $0.baseAddress!, count: 4)
        }
        XCTAssertTrue(shouldRunDFN)
        XCTAssertEqual(levelBox.pointee, 0)
    }
}
