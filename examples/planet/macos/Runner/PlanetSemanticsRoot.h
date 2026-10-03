#ifndef PLANET_SEMANTICS_ROOT_H
#define PLANET_SEMANTICS_ROOT_H

#include <stdbool.h>
#include <stdint.h>
#include <string.h>

// Stable prefixes of FlutterSemanticsUpdate2 and FlutterSemanticsNode2 from
// Flutter's embedder.h. The framework does not export that header on macOS.
// Read only these fields, after checking the append-only ABI's struct_size.
typedef struct {
  size_t struct_size;
  size_t node_count;
  const void *const *nodes;
} PlanetSemanticsUpdatePrefix;

static inline bool PlanetSemanticsHasRoot(const void *update) {
  if (update == NULL) return false;
  size_t size;
  memcpy(&size, update, sizeof(size));
  if (size < sizeof(PlanetSemanticsUpdatePrefix)) return false;
  PlanetSemanticsUpdatePrefix prefix;
  memcpy(&prefix, update, sizeof(prefix));
  if (prefix.nodes == NULL) return false;
  for (size_t i = 0; i < prefix.node_count; i++) {
    const void *node = prefix.nodes[i];
    if (node == NULL) continue;
    memcpy(&size, node, sizeof(size));
    if (size < sizeof(size_t) + sizeof(int32_t)) continue;
    int32_t id;
    memcpy(&id, (const char *)node + sizeof(size_t), sizeof(id));
    if (id == 0) return true;
  }
  return false;
}

#endif
