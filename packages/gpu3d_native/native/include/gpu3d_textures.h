#ifndef GPU3D_TEXTURES_H
#define GPU3D_TEXTURES_H
#include "gpu3d_images.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { uint8_t *data; size_t length; } Fg2TextureBytes;
/* CPU-only KTX2 Basis decoder, using the image status codes and limits.
 * Pointers must be valid and disjoint, output empty. Success owns a LE packet:
 * u32 width, height, sRGB (0/1), mip count; then u32 length + RGBA8 per mip.
 * Length limits count all RGBA levels. The 16+4*mips packet header is extra.
 */
uint32_t fg2_ktx2_decode(const uint8_t *input, size_t length,
    const Fg2ImageLimits *limits, Fg2TextureBytes *output);
/* Target: 0 RGBA8, 1 BC7, 2 ETC2 RGBA8, 3 ASTC 4x4. Packet word 2 is
 * storage format: 0/1 RGBA8, 3/4 BC7, 5/6 ETC2, 7/8 ASTC (linear/sRGB).
 * Limits count packed blocks, including complete blocks for mip tails.
 */
uint32_t fg2_ktx2_transcode(const uint8_t *input, size_t length,
    const Fg2ImageLimits *limits, uint32_t target, Fg2TextureBytes *output);
/* Release the unchanged owned descriptor, then clear it. */
void fg2_ktx2_free(Fg2TextureBytes *output);
#ifdef __cplusplus
}
#endif
#endif
