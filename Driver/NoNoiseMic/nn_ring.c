#include "nn_ring.h"
#include <string.h>

static int is_pow2(uint32_t x) { return x != 0 && (x & (x - 1)) == 0; }

int nn_ring_init(nn_ring *r, float *storage, uint32_t capacityFrames, uint32_t channels) {
    if (!r || !storage || channels == 0 || !is_pow2(capacityFrames)) return -1;
    r->storage = storage;
    r->capacityFrames = capacityFrames;
    r->channels = channels;
    return 0;
}

void nn_ring_clear(nn_ring *r) {
    memset(r->storage, 0, (size_t)r->capacityFrames * r->channels * sizeof(float));
}

void nn_ring_write_at(nn_ring *r, uint64_t sampleTime, const float *src, uint32_t frames) {
    const uint32_t mask = r->capacityFrames - 1;
    const uint32_t ch = r->channels;
    for (uint32_t i = 0; i < frames; i++) {
        uint32_t slot = (uint32_t)((sampleTime + i) & mask);
        memcpy(&r->storage[(size_t)slot * ch], &src[(size_t)i * ch], ch * sizeof(float));
    }
}

void nn_ring_read_at(nn_ring *r, uint64_t sampleTime, float *dst, uint32_t frames) {
    const uint32_t mask = r->capacityFrames - 1;
    const uint32_t ch = r->channels;
    for (uint32_t i = 0; i < frames; i++) {
        uint32_t slot = (uint32_t)((sampleTime + i) & mask);
        memcpy(&dst[(size_t)i * ch], &r->storage[(size_t)slot * ch], ch * sizeof(float));
    }
}
