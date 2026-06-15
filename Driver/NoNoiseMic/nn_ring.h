// nn_ring.h — CoreAudio-free fixed circular buffer indexed by absolute sample time.
// Single-writer (output IO cycle) / single-reader (input IO cycle); the shared HAL
// clock keeps the reader trailing the writer. No locks, no allocation, no syscalls.
//
// Layout is INTERLEAVED: storage holds `capacityFrames * channels` floats laid out as
// [f0c0, f0c1, f1c0, f1c1, ...]. The driver passes the HAL's interleaved ioMainBuffer
// straight in/out — there is exactly one canonical layout (see the plan's contract table).
#ifndef NN_RING_H
#define NN_RING_H
#include <stdint.h>
#include <stddef.h>

typedef struct {
    float   *storage;        // caller-owned: capacityFrames * channels floats
    uint32_t capacityFrames; // MUST be a power of two
    uint32_t channels;
} nn_ring;

// Initialize. capacityFrames MUST be a power of two. Returns 0 on success, -1 on bad args.
int  nn_ring_init(nn_ring *r, float *storage, uint32_t capacityFrames, uint32_t channels);

// Zero the storage.
void nn_ring_clear(nn_ring *r);

// Write `frames` interleaved frames starting at absolute sample time `sampleTime`,
// wrapping modulo capacity. `src` length = frames * channels.
void nn_ring_write_at(nn_ring *r, uint64_t sampleTime, const float *src, uint32_t frames);

// Read `frames` interleaved frames starting at absolute sample time `sampleTime`,
// wrapping modulo capacity, into `dst` (length = frames * channels).
void nn_ring_read_at(nn_ring *r, uint64_t sampleTime, float *dst, uint32_t frames);

#endif
