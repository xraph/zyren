# Native GPU timing

You can inspect the last completed scene submission through a native backend:

```dart
final inspection = await backend.inspectGpu();
print(inspection.lastSubmissionGpuTimeNs);
print(inspection.gpuTimeSource);
```

Plugins use `context.inspectGpu()`. The result can be null when a backend does
not implement diagnostics. A null duration means the native timing measurement
was unavailable. Don't replace it with CPU elapsed time.

Metal uses command-buffer start and end times. Vulkan and DX12 use two timestamp
queries when the adapter supports both timestamp queries and encoder timestamp
writes. The renderer requests those features together and multiplies the tick
difference by the queue's timestamp period. Unsupported adapters keep rendering
with an unavailable duration. Counter wraparound and invalid periods also leave
the measurement unknown.

The query path owns two queries and two 16-byte buffers per renderer, shared by
its views. It resolves and maps the counters with the scene submission, then
reads them after the existing completion wait. There is no additional blocking
GPU wait. Failed submissions clear the previous timing and follow the normal
renderer retirement path.

`gpuTimeSource` identifies `metal.commandBuffer.startEndTime`,
`wgpu.timestampQuery.commandEncoder` or `unavailable`. These measurements cover
the recorded scene work, including GPU copies and gaps between passes. They
exclude Dart scene capture, CPU encoding and reading mapped pixels. Backend and
driver timestamp placement can differ, so keep the source with your results.

Timestamp metadata is separate from pixel capture. Reading 16 bytes of counters
does not increment `FrameStats.readbackBytes`; explicit image capture still
reports its transferred RGBA bytes. GPU time also does not measure display
refresh intervals. Record presentation completion intervals and end-to-end
capture latency separately when comparing frame pacing.

Native tests repeat submissions and inspections, check feature admission and
invalid durations, and verify pixel-readback counters. The device SceneView
fixture prints its timing source and duration alongside presentation readback.
Windows runtime qualification still requires a Windows execution target.

## Area-light comparison

From the repository root, run the repeatable readback fixture:

```sh
dart run packages/zyren_native/tool/physical_area_benchmark.dart /tmp/area-profile
```

You'll get raw GPU timings, end-to-end capture timings and four RGBA images.
Each material warms up for 120 frames before 120 measured frames at 512x384.
The fixture includes clearcoat and sheen, then varies anisotropy and thin film.

On the Apple M3 Max with macOS 27, the longer comparison produced these medians:

| Material | Before, GPU ms | After, GPU ms | Largest RGBA difference |
| --- | ---: | ---: | ---: |
| Isotropic | 0.6729 | 0.2470 | 0 |
| Anisotropic | 1.6264 | 0.5789 | 1 in one byte |
| Thin film | 2.1258 | 1.2453 | 0 |
| Anisotropy and thin film | 2.1236 | 1.2503 | 0 |

The baseline uses the shaders from `b216ef8`. The change prepares view-dependent
GGX, sheen and coat values once per area-light integration and skips Fresnel
evaluation for a dielectric or metal component with zero weight. All 64 area
samples remain. Three fixtures match every RGBA byte; the fourth differs in one
of 786,432 bytes by one step.

Shorter repeated runs varied substantially, including the isotropic control.
Treat the table as one host's observations, not a portable speedup factor or an
isolated estimate of each optimization. These are GPU and readback measurements;
they do not establish native presentation pacing. The 19 native material, map,
area-shadow, transmission and optics checks also pass after the shader change.
