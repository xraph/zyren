#ifndef FLUTTER_GPU3D_H
#define FLUTTER_GPU3D_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

uint32_t fg_abi_version(void);
/* Returns zero on failure. Handles are opaque, process-local and never reused. */
uint64_t fg_create(void);
/* Process-local diagnostic. Does not expose handles or GPU pointers. */
size_t fg_live_renderer_count(void);
/* Returns one on success, zero on failure. */
uint32_t fg_destroy(uint64_t handle);
/* Fallback cleanup for Dart isolate teardown. Token encodes a handle. */
void fg_finalize(void *token);
/* UTF-8 bytes, no terminator. Returns full length and copies up to capacity. */
size_t fg_last_error(uint8_t *buffer, size_t capacity);
/* All pointers remain caller-owned. Pixels are tightly packed opaque RGBA8 sRGB.
 * JSON and pixels must be valid non-overlapping buffers of the declared sizes.
 * Dimensions: 1..4096. JSON limit: 128 MiB. Blocking, call off the UI thread.
 * Returns one on success, zero on failure. Read fg_last_error on the same thread.
 */
uint32_t fg_render(uint64_t handle, const uint8_t *json, size_t json_len,
                   uint32_t width, uint32_t height, uint8_t *pixels, size_t capacity);

#ifdef __cplusplus
}
#endif
#endif
