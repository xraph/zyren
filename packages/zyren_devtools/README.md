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
Metal needs no timestamp buffers or diagnostic readbacks. On Vulkan and DX12,
the first query arms two timestamp slots when the adapter supports encoder
timestamps. A later rendered frame makes a sample available. Each subsequent
inspection reads 16 bytes on demand, reported by `diagnosticReadbackBytes`.
`gpuTimeSource` is `awaitingInstrumentedSubmission` before that first instrumented
frame, or `unavailable` when the adapter lacks timestamp support. The scratch
resources live only as long as the native renderer and retain no frame history.

`allocatorUsedBytes` and `allocatorReservedBytes` come from wgpu's suballocator
report on supported Vulkan/DX12 devices. Used bytes cover allocated ranges;
reserved bytes include unused portions of allocator blocks. Imported resources,
driver overhead and allocations outside that device's suballocator are excluded.
`allocatorAllocations` contains names, block-relative offsets and sizes, capped
by `allocationLimit`. Names are capped at 128 UTF-8 bytes. Check
`allocatorAllocationCount` and `allocatorTruncated` for omitted entries. Unsupported
reports remain null with `allocatorSource: unavailable`. These counters do not
measure physical residency or total device memory.

`memoryReports` exposes native usage and budget queries. Each report carries
`status`, `source`, `scope` and `region`, with optional `heapIndex`, `nodeIndex`,
`deviceLocal` and `unifiedMemory` metadata. You can inspect it directly:

```dart
final inspection = await inspector.inspectGpu();
for (final memory in inspection?.memoryReports ?? <GpuMemoryReport>[]) {
  if (memory.status == 'available') {
    print('${memory.source}: ${memory.usageBytes} / ${memory.budgetBytes}');
  } else {
    print('${memory.status}: ${memory.reason}');
  }
}
```

| Source | Scope and measurements |
| --- | --- |
| `metal.deviceMemory` | `processDevice`: `usageBytes` reads `currentAllocatedSize`. `recommendedMaxWorkingSetBytes` is approximate performance guidance, available on macOS and iOS 16 or later. `budgetBytes` stays null. |
| `vulkan.EXT_memory_budget` | `processHeap`: one report per heap, identified by `heapIndex`. `usageBytes` and `budgetBytes` are driver estimates, marked with `usageIsEstimate` and `budgetIsEstimate`. |
| `dxgi.QueryVideoMemoryInfo` | `processAdapterSegment`: OS-reported usage and budget for each linked node's local and non-local segment. The query resolves the renderer device's adapter LUID. |

Check `status` before using a number. Unsupported queries return `unsupported`
with a reason; failed DXGI queries return `error` and the HRESULT in `reason`.
One failed segment does not discard the other segment's report. Missing values
stay null, while a reported zero stays zero. Older runtimes return an empty list.
On iOS 13 through 15, the Metal allocation counter remains available and the
working-set recommendation stays null.

These snapshots can change as other applications allocate memory. Usage can
exceed the current budget. Keep heap and segment reports separate, and don't add
them to the device or allocator counters, since their coverage overlaps. The
memory queries allocate no GPU resources and perform no GPU readback; the timing
query's diagnostic readbacks are still counted separately. No report measures
physical residency.

You can compare these fields with the native API definitions:
[Metal device memory](https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize),
[Vulkan memory budgets](https://docs.vulkan.org/spec/latest/chapters/memory.html),
and [DXGI video memory](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_4/ns-dxgi1_4-dxgi_query_video_memory_info).

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
submission count and allocation changes, then checks cleanup. The separate
`examples/multiple_views/integration_test/gpu_diagnostics_test.dart` exercises
Flutter native Metal and Android Vulkan presentation, read-only queries and
attachment cleanup. Run it on each target device before claiming qualification.
DX12 needs a Windows runner; passing Metal or Vulkan tests does not qualify it.

The native-view test passed on macOS Metal, a Pixel 9 Pro running Android 17,
and an iPhone 16 Pro running iOS 27 on 2026-10-02. All three checks kept scene
pixel readbacks at zero and verified renderer, presentation surface and bridge
cleanup. The Pixel reported a completed GPU timestamp sample and a bounded
allocator report. The iPhone passed positive Metal GPU timing and device
allocation checks in profile mode over a wireless connection.

To repeat the iPhone check, run this from `examples/multiple_views` with your
unlocked device ID:

```sh
flutter drive --profile --driver=test_driver/qualification.dart \
  --target=integration_test/gpu_diagnostics_test.dart -d <device-id> --publish-port
```

DX12 still requires a Windows runner.

The memory-report additions passed the macOS native-view test and the Dart,
CLI/MCP and Rust checks. On the Pixel 9 Pro, the Mali-G715 driver does not
advertise `VK_EXT_memory_budget`; the test verified the explicit unsupported
report, retained allocator counters and cleanup. A positive Vulkan budget sample
still needs a driver that supports the extension. The DXGI implementation and
its device test type-check for Windows x64, but live DXGI verification still
requires Windows hardware.

The updated iPhone 16 Pro test passed in profile mode on iOS 27. Metal reported
95,567,872 allocated bytes and a 5,726,633,984-byte recommended working set.
Scene pixel readbacks and diagnostic GPU readbacks stayed at zero, and renderer,
drawable and bridge cleanup passed. You can inspect the captured result in
[the iPhone memory report](qualification/2026-10-02-ios-memory.json).

To qualify the DXGI report on a Windows GPU host, run this from the repository
root. This test explicitly selects DX12, even if Vulkan is also installed:

```sh
cargo test --manifest-path packages/zyren_native/native/Cargo.toml --lib \
  dx12_memory_reports_query_the_selected_adapter -- --include-ignored --nocapture
```

## AI diagnostics and local tools

`SceneDiagnostics(inspector)` exposes a versioned JSON inspection API, conservative
blank-scene checks and bounded diagnostic reports. Call `recordIssue` with host
issues, including initialization failures. No model is required by the package.

The optional `package:zyren_devtools/io.dart` library provides a token-protected
loopback bridge and a stdio MCP server. The `zyren` executable can inspect the
same session from your terminal or MCP client. Networking starts only when your
host explicitly calls `DevtoolsServer.start`; close the server during cleanup.

See [AI setup](guides/README.md) for workbench commands, MCP configuration,
result limits and a compiled authoring recipe. See the
[agent guide](guides/AGENT_GUIDE.md) for current API conventions.
