# Cloud shadows and render cost

You can now turn cloud shadows off and choose their quality separately in Planet's
Google cloud lab. Auto follows cloud quality. The switch preserves your selected
shadow quality and removes the shadow atlas, cascade work, shadow history and
light shafts while leaving the clouds visible.

The core API is `CloudQualitySettings(shadowsEnabled: false)` or
`CloudQualitySettings(shadowPreset: CloudQualityPreset.low)`. Pass the settings to
`CloudController.setQualitySettings`. A failed replacement keeps the active
settings and resources available.

## Work removed

- The cloud producer, temporal resolve and publication now draw into their own
  sized color attachments. Previously, each stage rasterized the scene viewport
  and discarded fragments outside its smaller storage targets. At a 1280x720
  viewport with a 640x360 cloud target and quarter-edge raw rays, those three
  stages cover 475,200 fragments instead of 2,764,800. This count covers only
  those stages, not the complete frame.
- Filterable weather and turbulence maps use the GPU's repeat and linear mip
  sampler. R32Float volumes keep explicit interpolation. Integer mip samples
  no longer calculate the same level twice.
- Shadows off allocates no shadow atlas or shadow render graph. The native
  lighting regression checks that ground darkening disappears and returns when
  shadows are enabled again.

The pinned Takram source already uses sized cloud render targets and hardware
texture sampling. Its Tokyo story animates the clouds and updates shadows each
frame too. Disabling animation would change that story's behavior.

## Verification

Core Metal tests cover sampling at repeat seams and fractional mip levels,
shadow removal, ground lighting, cloud rendering and temporal history. Ten tests
passed after the filtering change. Four temporal resolve tests also passed with
a larger, nonmatching scene viewport; the scene background stayed unchanged.
Three Planet widget tests passed, including shadow controls at 1000px and 390px.
Dart analysis passed for the changed library, UI, integration fixture and timing
fixture.

The macOS Metal profile integration passed shadows off, Low shadows and Ultra
shadows while keeping High cloud quality. It presented 101 frames, retained
16-frame cloud history after replacement and resize, and ended with zero
sessions, renderers, retiring resources, held drawables and readback bytes.
The physical Pixel 9 Pro Vulkan profile run passed the same sequence. It
presented 104 frames and ended with zero sessions, surfaces, renderers, retiring
resources and readback bytes. The fixture uses small targets to verify behavior;
it is not a performance test.
Normal Google cloud-lab profile apps were restored on macOS and Pixel after the
tests. The macOS app accepted the shadow switch and Low shadow quality with live Tokyo
tiles visible, while cloud quality stayed High.
Earlier Apple quality evidence at revision `23561c4` does not cover these changes.

## Timing limits

Run the small native fixture from `packages/zyren_geospatial`:

```sh
fvm dart run tool/cloud_render_cost.dart
```

[Recorded samples](cloud-render-cost.json) compare `382115e`, before the raster
and filtering changes, with `cb9276a`. Each case warms 20 frames and measures 48.
It uses procedural clouds, no provider tiles, a fixed camera and elapsed time,
Dart JIT and CPU image readback. Planet was closed, but other development builds
were not suspended. These timings cannot establish interactive FPS or loading
parity with the Takram city scene.

| Per-run median, three runs | Before | After |
| --- | --- | --- |
| Shadows on | 31.2 to 40.0 ms | 24.5 to 34.3 ms |
| Shadows off | 22.2 to 23.7 ms | 17.1 to 31.6 ms |

The ranges overlap. There is no claimed frame-rate improvement from these
samples. Disabling shadows reduced the fixture's resident GPU resources from
45,010,036 to 42,650,468 bytes, and its median render time fell in each paired run.

## Flutter and remaining work

The workspace stays on Flutter 3.47.5. Runtime logs already show Impeller on
Metal and Vulkan. Flutter composites the interface; Zyren's Rust/wgpu renderer
runs the cloud and atmosphere shaders. [Impeller's role](https://docs.flutter.dev/perf/impeller)
and [profile-mode guidance](https://docs.flutter.dev/perf/rendering-performance)
are documented by Flutter.

Flutter 3.47.6 was reviewed as an available patch. It was not installed during
this change. The host had about 7 GiB free before native profile builds, and an
SDK update would need its own device checks. It would not remove these custom
shader passes.

Our cloud output remains capped by device settings, so large displays still
upscale a smaller cloud image. The restored Tokyo view also reported detail
limited by its tile memory budget: 64 MiB on desktop and tablet, 48 MiB on phone.
That limits geometry refinement independently of cloud rendering. Full source
image comparison remains open.
Apple resource graph submission also waits for GPU completion between graphs;
its contribution needs GPU timing before changing synchronization. A matched
Tokyo profile run still needs to separate tile loading, cloud marching,
composition and CPU/GPU waits.
