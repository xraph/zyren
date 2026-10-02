# zyren_devtools

Inspect a scene without importing the native renderer or Flutter.

```dart
final inspector = SceneDevtoolsPlugin(historyLimit: 120);
controller.use(inspector);
await controller.ready;
final sceneInfo = inspector.snapshot();
final object = inspector.objectFor(sceneInfo.nodes.first.id);
final recentFrames = inspector.frames;
```

Snapshots copy hierarchy, local transforms, visibility and mesh information.
IDs stay stable within one inspector instance. `objectFor` resolves only objects
still in the attached scene, so an old snapshot cannot retain a removed mesh.
You can inspect inherited visibility separately from a node's own flag.

`frames` returns a copy of the bounded frame history. GPU time and resident bytes
remain null when the backend cannot report them. Resource payload counters are
not total GPU memory.
Detaching clears frame history and disables scene queries.

Dependent plugins can request the exported `sceneDevtools` service key after
declaring `zyren.devtools` as a dependency. Flutter hosts can use the controller's
sampled `frameStats` stream to refresh their diagnostics UI.

You can query native measurements with `await inspector.inspectGpu()`.
The query runs on demand and keeps no inspection history. `allocationLimit`
accepts 1 to 256 entries (128 by default). `totalAllocations` and `truncated`
show whether the copied list covers the registry.

On Metal, `deviceAllocatedBytes` reads `MTLDevice.currentAllocatedSize`.
It covers Metal resource allocations on that device in this process, including
other views or renderers sharing the device. It does not measure physical
residency, driver overhead or system GPU memory. `residentBytes` stays null.

`registryPayloadBytes` and each allocation's `payloadBytes` count resource
payload sizes. The list covers scoped buffers, textures and uploaded scene
geometry, including released resources awaiting submission retirement. Frame
targets, pipeline objects and temporary staging allocations are excluded.
IDs include registry, device and slot generations; they cannot be used as
resource handles. Queries do not retain resources.

`lastSubmissionGpuTimeNs` uses completed Metal command-buffer start/end times.
It covers the last scene submission, including gaps between its buffers.
CPU encoding, queue wait, resource uploads and CPU pixel readback are excluded.
`submittedFrames` identifies the device submission count, shared across views.
No timestamp buffers or extra readbacks are required. Vulkan and DX12 report
allocation and timing measurements as unavailable until implemented and tested.

For a native CLI sample:

```sh
dart run packages/zyren_devtools/example/gpu_inspect.dart
```

Add `--mcp` for newline JSON-RPC over stdin/stdout. The example creates its own
device and renders a box. To inspect your running host, import `gpu_tools.dart`
and embed `GpuInspectionTools` with that host's attached inspector. The exported
`zyren_gpu_inspect` tool shares the inspector's bounded, read-only query. Native
imports belong to the example; the inspector and adapter need only Dart core.

To inspect a running host, add the bridge after your inspector:

```dart
import 'package:zyren_devtools/gpu_bridge.dart';

final inspector = SceneDevtoolsPlugin();
final bridge = GpuInspectionBridge();
// Pass [inspector, bridge] as the host's scene plugins.
// Read bridge.endpoint and bridge.sessionToken after attachment succeeds.
```

Give the CLI the endpoint and token through `ZYREN_GPU_ENDPOINT` and
`ZYREN_GPU_SESSION_TOKEN`, then run:

```sh
dart run packages/zyren_devtools/example/gpu_inspect.dart --remote
# Add --mcp to expose that host's query over stdio.
```

Remote mode creates no GPU device. You can also use `GpuInspectionClient`
directly and call `close()` when finished. The client accepts only an explicit
HTTP endpoint at `127.0.0.1`, bypasses proxies and rejects redirects.

The bridge starts only when you attach its plugin. It listens on an ephemeral
IPv4 loopback port, requires a random session token and rejects browser origins.
Requests are limited to 8 KiB, responses to 256 KiB in the client, and only one
inspection runs at a time. Keep the token private. Detaching closes the listener
and clears the token through the plugin attachment scope. No measurements or
allocation lists are cached by the bridge.

The remote CLI/MCP regression runs against a native Metal host, verifies its
submission count and allocation changes, then checks cleanup. This does not
qualify Vulkan, DX12 or a Flutter native-view presentation path.
