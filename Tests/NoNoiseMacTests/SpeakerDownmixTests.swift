import XCTest
import CoreAudio
import CTapRing
@testable import Core

/// Host unit tests for the Speaker Tap IOProc's fixed stereo-interleaved→mono downmix
/// (`SpeakerCleanupEngine.downmixStereoInterleavedToRing`). Unlike `IncomingDownmixTests` (which
/// covers the general N-channel/planar-or-interleaved case for an arbitrary process tap), this path's
/// format is the driver's FIXED canonical ASBD — always exactly 2 interleaved channels — confirmed
/// once in `start()` before the IOProc is ever installed. No `@available` gate on this function (the
/// Speaker Cleanup path uses no macOS-14.4-only API), so no `XCTSkip` is needed.
final class SpeakerDownmixTests: XCTestCase {

    // MARK: - Builders (no CoreAudio device needed — plain in-memory buffers)

    private func makeFloatBuffer(_ values: [Float]) -> UnsafeMutablePointer<Float> {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, values.count))
        p.initialize(repeating: 0, count: max(1, values.count))
        for i in values.indices { p[i] = values[i] }
        return p
    }

    private func drain(_ ring: TapAudioRing, _ count: Int) -> [Float]? {
        var out = [Float](repeating: .nan, count: count)
        let ok = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: count) }
        return ok ? out : nil
    }

    // MARK: - Tests

    func testInterleavedStereoAveragesToMono() throws {
        // [L,R] interleaved: (1,3)(2,6)(3,9)(4,12) → mono mean = 2,4,6,8
        let interleaved = [Float]([1, 3, 2, 6, 3, 9, 4, 12])
        let nFrames = interleaved.count / 2
        let src = makeFloatBuffer(interleaved)
        defer { src.deinitialize(count: interleaved.count); src.deallocate() }

        let abl = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(abl.unsafeMutablePointer) }
        abl[0] = AudioBuffer(mNumberChannels: 2,
                             mDataByteSize: UInt32(interleaved.count * MemoryLayout<Float>.size),
                             mData: UnsafeMutableRawPointer(src))

        let ring = TapAudioRing(capacityFrames: 64)
        let scratch = makeFloatBuffer([Float](repeating: 0, count: 64))
        defer { scratch.deinitialize(count: 64); scratch.deallocate() }

        SpeakerCleanupEngine.downmixStereoInterleavedToRing(abl: abl, scratch: scratch, scratchCap: 64,
                                                            ring: ring.cRing)

        XCTAssertEqual(ring.availableToRead, nFrames)
        let out = try XCTUnwrap(drain(ring, nFrames))
        XCTAssertEqual(out, [2, 4, 6, 8])
    }

    func testSilenceStaysSilence() throws {
        let interleaved = [Float](repeating: 0, count: 8)
        let src = makeFloatBuffer(interleaved)
        defer { src.deinitialize(count: interleaved.count); src.deallocate() }

        let abl = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(abl.unsafeMutablePointer) }
        abl[0] = AudioBuffer(mNumberChannels: 2,
                             mDataByteSize: UInt32(interleaved.count * MemoryLayout<Float>.size),
                             mData: UnsafeMutableRawPointer(src))

        let ring = TapAudioRing(capacityFrames: 64)
        let scratch = makeFloatBuffer([Float](repeating: 0, count: 64))
        defer { scratch.deinitialize(count: 64); scratch.deallocate() }

        SpeakerCleanupEngine.downmixStereoInterleavedToRing(abl: abl, scratch: scratch, scratchCap: 64,
                                                            ring: ring.cRing)

        let out = try XCTUnwrap(drain(ring, 4))
        XCTAssertEqual(out, [0, 0, 0, 0])
    }

    /// A buffer larger than the scratch capacity must be chunked into the ring IN ORDER (the IOProc's
    /// `while off < frames` loop), never dropped or reordered.
    func testChunksAcrossScratchCapacity() throws {
        // 8 stereo frames, L=n, R=n+100 → mono mean = n+50 for n in 1...8
        var interleaved: [Float] = []
        var expected: [Float] = []
        for n in 1...8 {
            interleaved.append(Float(n)); interleaved.append(Float(n + 100))
            expected.append(Float(n) + 50)
        }
        let src = makeFloatBuffer(interleaved)
        defer { src.deinitialize(count: interleaved.count); src.deallocate() }

        let abl = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(abl.unsafeMutablePointer) }
        abl[0] = AudioBuffer(mNumberChannels: 2,
                             mDataByteSize: UInt32(interleaved.count * MemoryLayout<Float>.size),
                             mData: UnsafeMutableRawPointer(src))

        let ring = TapAudioRing(capacityFrames: 64)
        let scratch = makeFloatBuffer([Float](repeating: 0, count: 3))   // cap 3 < 8 frames → 3 chunks
        defer { scratch.deinitialize(count: 3); scratch.deallocate() }

        SpeakerCleanupEngine.downmixStereoInterleavedToRing(abl: abl, scratch: scratch, scratchCap: 3,
                                                            ring: ring.cRing)

        XCTAssertEqual(ring.availableToRead, expected.count)
        let out = try XCTUnwrap(drain(ring, expected.count))
        XCTAssertEqual(out, expected)
    }

    /// A buffer present but carrying zero bytes (0 frames) must be a no-op, not a crash — the
    /// `while off < frames` loop simply never executes. (A buffer LIST with zero buffers is not
    /// exercised here: `AudioBufferList.allocate(maximumBuffers: 0)` itself is not a safe construct,
    /// independent of anything under test.)
    func testZeroByteBufferIsNoOp() {
        let src = makeFloatBuffer([])
        defer { src.deinitialize(count: 1); src.deallocate() }

        let abl = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(abl.unsafeMutablePointer) }
        abl[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 0, mData: UnsafeMutableRawPointer(src))

        let ring = TapAudioRing(capacityFrames: 64)
        let scratch = makeFloatBuffer([Float](repeating: 0, count: 64))
        defer { scratch.deinitialize(count: 64); scratch.deallocate() }

        SpeakerCleanupEngine.downmixStereoInterleavedToRing(abl: abl, scratch: scratch, scratchCap: 64,
                                                            ring: ring.cRing)
        XCTAssertEqual(ring.availableToRead, 0)
    }
}
