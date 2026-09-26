#ifndef GPU3D_H
#define GPU3D_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
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
  FG2_TIMED_OUT = 13
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
/* This is an identity token, not a pointer or an authorization credential. */
uint64_t fg2_runtime_token(void);
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
