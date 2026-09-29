#ifndef ZYREN_IMAGES_H
#define ZYREN_IMAGES_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
  uint32_t version; /* 1 */
  uint32_t max_dimension;
  uint64_t max_encoded_bytes;
  uint64_t max_decoded_bytes;
  uint64_t max_working_bytes;
} Fg2ImageLimits;
typedef struct {
  uint32_t width;
  uint32_t height;
  uint8_t *pixels;
  size_t length;
} Fg2ImagePixels;
/* CPU-only. Status: 0 success, 1 invalid data, 2 unsupported format,
 * 3 unsupported color, 4 limit exceeded, 5 busy, 6 internal, 7 invalid limits.
 * All pointers must be valid and disjoint. Output must be empty. Success
 * returns owned top-down straight-alpha RGBA8 bytes. Free them before reuse.
 */
uint32_t fg2_image_decode(const uint8_t *input, size_t length,
    const Fg2ImageLimits *limits, Fg2ImagePixels *output);
/* Accepts the unchanged descriptor returned above, clears it on release.
 * Never copy the descriptor's ownership or use its pixels after release.
 */
void fg2_image_free(Fg2ImagePixels *output);
typedef struct {
  uint32_t width;
  uint32_t height;
  float *pixels;
  size_t length; /* float components, not bytes */
} Fg2HdrImagePixels;
/* CPU-only Radiance RGBE profile, same status codes and limits as above.
 * Returns owned top-down opaque RGBA32F. Values are linear, as stored.
 * Missing primaries assume linear sRGB; explicit other primaries, XYZE and
 * non-square pixels are unsupported. EXPOSURE/COLORCORR are not reapplied.
 * All pointers must be valid and disjoint. Output must be empty.
 */
uint32_t fg2_hdr_image_decode(const uint8_t *input, size_t length,
    const Fg2ImageLimits *limits, Fg2HdrImagePixels *output);
/* Same ownership contract as fg2_image_free. */
void fg2_hdr_image_free(Fg2HdrImagePixels *output);
#ifdef __cplusplus
}
#endif
#endif
