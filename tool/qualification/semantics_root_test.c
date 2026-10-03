#include <assert.h>
#include <stddef.h>
#include "embedder.h"
#include "../../examples/planet/macos/Runner/PlanetSemanticsRoot.h"

// Build with the pinned Flutter SDK's shell/platform/embedder include directory.
// This checks the actual engine ABI, including updates with additional fields.
_Static_assert(offsetof(FlutterSemanticsUpdate2, node_count) ==
                   offsetof(PlanetSemanticsUpdatePrefix, node_count), "node_count ABI");
_Static_assert(offsetof(FlutterSemanticsUpdate2, nodes) ==
                   offsetof(PlanetSemanticsUpdatePrefix, nodes), "nodes ABI");
_Static_assert(offsetof(FlutterSemanticsNode2, id) == sizeof(size_t), "node ID ABI");

int main(void) {
  FlutterSemanticsNode2 child = {.struct_size = sizeof(child), .id = 30};
  FlutterSemanticsNode2 root = {.struct_size = sizeof(root), .id = 0};
  FlutterSemanticsNode2 *nodes[] = {&child, NULL, &root};
  FlutterSemanticsUpdate2 update = {
      .struct_size = sizeof(update), .node_count = 1, .nodes = nodes};
  assert(!PlanetSemanticsHasRoot(NULL));
  assert(!PlanetSemanticsHasRoot(&update));
  update.node_count = 3;
  assert(PlanetSemanticsHasRoot(&update));
  root.struct_size = sizeof(size_t);
  assert(!PlanetSemanticsHasRoot(&update));
  root.struct_size = sizeof(root);
  update.struct_size = sizeof(size_t);
  assert(!PlanetSemanticsHasRoot(&update));
  update.struct_size = sizeof(update);
  update.nodes = NULL;
  assert(!PlanetSemanticsHasRoot(&update));
  return 0;
}
