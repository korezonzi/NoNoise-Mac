import Foundation

/// Fixed-capacity ring buffer of `Float` values for ML feature history.
///
/// **Semantic:** the buffer is always full after `init` — pre-loaded with zeros
/// in every slot. `append(_:)` shifts the head pointer and overwrites the oldest
/// values, never growing past `capacity`. `copyChronological(into:)` always writes
/// exactly `capacity` values in oldest-first order, with unwritten slots left as
/// zero. This matches the pre-existing `[Float](repeating: 0, count: capacity)`
/// arrays that the CoreML input MLMultiArrays expect.
final class SpecHistoryRingBuffer {
    private var storage: [Float]
    private var head: Int = 0  // index of the oldest element
    let capacity: Int

    /// Always equal to `capacity` after init. Exposed for parity with the
    /// pre-ring-buffer `[Float]` arrays it replaces.
    var count: Int { capacity }

    init(capacity: Int) {
        precondition(capacity > 0, "capacity must be > 0")
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    /// Append a chunk. If `chunk.count >= capacity`, only the last `capacity`
    /// values are kept and the head resets to 0.
    ///
    /// **Allocation note:** the `chunk.count >= capacity` path calls
    /// `Array(chunk.suffix(capacity))`, which allocates a new backing buffer.
    /// In DSP use, chunks (e.g. 962 floats per hop) are always much smaller
    /// than capacity (e.g. 9620), so the allocation path is never taken in
    /// practice. If a caller is going to pass chunks of arbitrary size, be
    /// aware of this.
    func append(_ chunk: [Float]) {
        if chunk.isEmpty { return }
        if chunk.count >= capacity {
            storage = Array(chunk.suffix(capacity))
            head = 0
            return
        }
        let writeStart = (head + capacity) % capacity
        if writeStart + chunk.count <= capacity {
            // No wrap
            for (i, v) in chunk.enumerated() {
                storage[writeStart + i] = v
            }
        } else {
            // Wrap around
            let firstChunk = capacity - writeStart
            for i in 0..<firstChunk { storage[writeStart + i] = chunk[i] }
            for i in 0..<(chunk.count - firstChunk) { storage[i] = chunk[firstChunk + i] }
        }
        head = (head + chunk.count) % capacity
    }

    /// Copy all `capacity` values into `out` in chronological order (oldest first).
    /// `out.count` must equal `self.capacity`.
    func copyChronological(into out: inout [Float]) {
        precondition(out.count == capacity,
                     "out.count (\(out.count)) must equal capacity (\(capacity))")
        if capacity == 0 { return }
        if head == 0 {
            for i in 0..<capacity { out[i] = storage[i] }
        } else {
            let firstChunk = capacity - head
            for i in 0..<firstChunk { out[i] = storage[head + i] }
            for i in 0..<head { out[firstChunk + i] = storage[i] }
        }
    }
}
