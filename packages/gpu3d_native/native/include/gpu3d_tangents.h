#ifndef GPU3D_TANGENTS_H
#define GPU3D_TANGENTS_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
  uint32_t version; /* 1 */
  uint64_t max_working_bytes; /* C scratch including allocation headers, <= 128 MiB */
  uint64_t max_iterations; /* Reference loop conditions, <= 100000000 */
} Fg2TangentLimits;
/* CPU-only MikkTSpace. Inputs have vertex_count * (3, 3, 2) float components
 * and corner_count indices. Output has corner_count * 4 float components.
 * All buffers must be valid, disjoint, and remain caller-owned. Output is
 * unspecified on failure. Positions and UVs must be finite and within +/-1e15.
 * Status: 0 success, 1 invalid data/limits, 2 limit exceeded, 3 busy, 4 internal.
 */
uint32_t fg2_generate_tangents(const float *positions, const float *normals,
    const float *uvs, uint32_t vertex_count, const uint32_t *indices,
    uint32_t corner_count, const Fg2TangentLimits *limits,
    float *output, size_t output_length);
#ifdef __cplusplus
}
#endif
#endif
