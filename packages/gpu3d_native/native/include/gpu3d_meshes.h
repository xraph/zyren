#ifndef GPU3D_MESHES_H
#define GPU3D_MESHES_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
  uint32_t version, max_vertices, max_triangles, max_attributes;
  uint64_t max_encoded_bytes, max_decoded_bytes;
} Fg2MeshLimits;
typedef struct { uint8_t *data; size_t length; } Fg2MeshBytes;
/* Status: 0 success, 1 invalid, 2 limits, 3 unsupported, 4 busy, 5 internal.
 * CPU-only Draco 2.2 triangle meshes. Input, limits and output are disjoint.
 * Output must start empty. Success transfers packet ownership to the caller.
 * Packet: LE u32 vertex/index/attribute counts, u32 indices, then attributes.
 * Each attribute: LE u32 ID/type/components/normalized/length, packed bytes.
 * Types: 0 i8, 1 u8, 2 i16, 3 u16, 4 u32, 5 f32.
 */
uint32_t fg2_draco_decode(const uint8_t *input, size_t length,
    const Fg2MeshLimits *limits, Fg2MeshBytes *output);
/* Clears and frees the unchanged returned descriptor. Empty is allowed. */
void fg2_draco_free(Fg2MeshBytes *output);
#ifdef __cplusplus
}
#endif
#endif
