#ifndef GPU3D_RESOURCES_H
#define GPU3D_RESOURCES_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Status values belong to this resource API, independently of Fg2Status. */
typedef enum {
  FG2_RESOURCE_OK = 0,
  FG2_RESOURCE_INVALID_COMMAND = 1,
  FG2_RESOURCE_STALE_KEY = 2,
  FG2_RESOURCE_BUDGET_EXCEEDED = 3,
  FG2_RESOURCE_INVALID_USAGE = 4,
  FG2_RESOURCE_INVALID_RANGE = 5,
  FG2_RESOURCE_DEVICE_FAILED = 6
} Fg2ResourceStatus;
/* Input and response packets use the little-endian format in
 * docs/design/gpu-resources.md. Buffers are borrowed for this call only and
 * must not overlap. `written` points to writable size_t storage. On success,
 * it contains the response length; on error, read fg_last_error for details.
 * Resource calls must use the same renderer handle as fg_render.
 */
uint32_t fg2_resource_command(uint64_t renderer, const uint8_t *input,
    size_t length, uint8_t *output, size_t capacity, size_t *written);
/* fg_render and native presentation entrypoints also accept binary scene
 * packets (version 2, opcode 10). Each positive view ID owns a revision stream.
 * Close releases that view's geometry references after its work completes.
 * Returns 1 on success, 0 on error; read fg_last_error for details.
 * Statistics include explicit resources and scene geometry. Invalid renderer
 * handles return zero and set fg_last_error.
 */
uint32_t fg2_scene_close(uint64_t renderer, uint64_t view);
uint64_t fg2_scene_resident_bytes(uint64_t renderer);
uint64_t fg2_scene_uploaded_bytes(uint64_t renderer);
#ifdef __cplusplus
}
#endif
#endif
