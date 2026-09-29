#ifndef GPU3D_COMPRESSION_H
#define GPU3D_COMPRESSION_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* CPU-only. Caller owns both disjoint buffers. Output must be 4-byte aligned.
 * Status: 0 success, 1 invalid data/layout, 2 limit exceeded, 3 busy.
 * Mode: 0 attributes, 1 triangles, 2 index sequence.
 * Filter: 0 none, 1 octahedral, 2 quaternion, 3 exponential.
 * Output length must equal count * stride. Discard output on any error.
 * Limits: input <= 16 MiB, output <= 64 MiB, at most two active native calls.
 */
uint32_t fg2_meshopt_decode(const uint8_t *input, size_t input_len,
    size_t count, size_t stride, uint32_t mode, uint32_t filter,
    uint8_t *output, size_t output_len);
#ifdef __cplusplus
}
#endif
#endif
