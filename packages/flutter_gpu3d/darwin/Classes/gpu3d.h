#ifndef GPU3D_H
#define GPU3D_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Bounded UTF-8 JSON shader commands, version 1. Output capacity must be
 * 262144 bytes. Zero means a response, including compile diagnostics.
 * A nonzero return is a transport failure; read fg_last_error.
 */
uint32_t fg2_shader_command(uint64_t renderer, const uint8_t *input, size_t length,
                            uint8_t *output, size_t capacity, size_t *written);
/* The graph channel uses the same framing limits and status convention. */
uint32_t fg2_graph_command(uint64_t renderer, const uint8_t *input, size_t length,
                           uint8_t *output, size_t capacity, size_t *written);
#define FG2_ABI_VERSION 2
typedef enum {
  FG2_OK = 0,
  FG2_INVALID_ARGUMENT = 1,
  FG2_STALE_KEY = 2,
  FG2_STALE_EPOCH = 3,
  FG2_STALE_LEASE = 4,
  FG2_DUPLICATE_COMPLETION = 5,
  FG2_BACKPRESSURE = 6,
  FG2_SUSPENDED = 7,
  FG2_CLOSED = 8,
  FG2_NOT_READY = 9,
  FG2_BUDGET_EXCEEDED = 10,
  FG2_EXHAUSTED = 11,
  FG2_INTERNAL = 12,
  FG2_TIMED_OUT = 13,
  /* GPU work and geometry residency changes completed, but the frame's epoch
   * was revoked before publication. Unlike STALE_EPOCH, scene data was applied.
   */
  FG2_FRAME_SUPERSEDED = 14
} Fg2Status;
typedef enum {
  FG2_SURFACE_CREATING = 0,
  FG2_SURFACE_READY = 1,
  FG2_SURFACE_SUSPENDED = 2,
  FG2_SURFACE_CLOSING = 3,
  FG2_SURFACE_CLOSED = 4
} Fg2SurfaceState;
/* Native endian, fixed-width fields. Initialize struct_size and abi_version
 * on every input/output/error record. A status of zero means success.
 * Nonzero statuses leave output records unchanged. Error messages are UTF-8,
 * no terminator; message_length is the number of bytes present (at most 240).
 * All pointers remain caller-owned and must address their declared capacity.
 */
typedef struct {
  uint32_t struct_size, abi_version;
  uint64_t runtime_token, slot, generation;
} Fg2SurfaceKey;
typedef struct {
  uint32_t struct_size, abi_version;
  /* Two or three buffers, one or two producers. The memory budget must fit
   * a displayed frame and its replacement. Adapters also charge alignment.
   */
  uint32_t width, height, buffer_limit, max_in_flight;
  uint64_t memory_limit;
} Fg2SurfaceDescriptor;
typedef struct {
  uint32_t struct_size, abi_version;
  Fg2SurfaceKey key;
  uint64_t epoch;
  uint32_t width, height, state, reserved;
} Fg2SurfaceSnapshot;
typedef struct {
  uint32_t struct_size, abi_version, code, message_length;
  uint8_t message[240];
} Fg2Error;
typedef struct {
  uint32_t struct_size, abi_version;
  uint64_t epoch, frame_id, resident_bytes, readback_bytes;
} Fg2FrameReceipt;
uint32_t fg2_apple_available(void);
uint64_t fg2_apple_live_buffers(void);
uint64_t fg2_apple_presented_frames(void);
uint64_t fg2_apple_readback_bytes(void);
uint32_t fg2_apple_attach(uint64_t renderer, Fg2SurfaceKey key,
                        Fg2SurfaceSnapshot *output, Fg2Error *error);
uint32_t fg2_apple_render(uint64_t renderer, Fg2SurfaceKey key, uint64_t epoch,
                        uint64_t frame_id, const uint8_t *json, uint64_t length,
                        Fg2FrameReceipt *output, Fg2Error *error);
/* Native-only Flutter callback. Returns a retained CVPixelBufferRef. */
void *fg2_apple_copy_pixel_buffer(Fg2SurfaceKey key);
uint32_t fg2_surface_snapshot(Fg2SurfaceKey key, Fg2SurfaceSnapshot *output,
                             Fg2Error *error);
/* This is an identity token, not a pointer or an authorization credential. */
uint64_t fg2_runtime_token(void);
#ifdef __ANDROID__
/* Experimental native-only Vulkan surface bridge. ANativeWindow stays native.
 * Render returns 1 on completion, 2 to retry acquisition, or 0 with fg_last_error.
 * Callers serialize attach/render/present/detach per renderer.
 */
uint32_t fg_android_attach(uint64_t renderer, void *window, uint32_t width, uint32_t height);
uint32_t fg_android_render(uint64_t renderer, const uint8_t *json, size_t length);
uint32_t fg_android_present(uint64_t renderer);
uint32_t fg_android_detach(uint64_t renderer);
size_t fg_android_info(uint64_t renderer, uint8_t *buffer, size_t capacity);
#endif
/* Reserves metadata only. Platform adapters activate it after GPU setup. */
uint32_t fg2_surface_create(const Fg2SurfaceDescriptor *descriptor,
                           Fg2SurfaceSnapshot *output, Fg2Error *error);
uint32_t fg2_surface_resize(Fg2SurfaceKey key, uint64_t expected_epoch,
                           uint32_t width, uint32_t height,
                           Fg2SurfaceSnapshot *output, Fg2Error *error);
uint32_t fg2_surface_suspend(Fg2SurfaceKey key, uint64_t expected_epoch,
                            uint32_t suspended, Fg2SurfaceSnapshot *output,
                            Fg2Error *error);
/* Idempotent until the slot is recycled; old generations then return staleKey.
 * Closing with outstanding leases stops work but retains their ownership.
 */
uint32_t fg2_surface_close(Fg2SurfaceKey key, Fg2SurfaceSnapshot *output,
                          Fg2Error *error);
#ifdef __cplusplus
}
#endif
#endif
