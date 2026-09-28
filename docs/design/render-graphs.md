# Run native shader graphs

Use `NativeBackend.createGraphCompiler()` to run WGSL compute and procedural
render passes on the backend's native device. You can bind scoped buffers and
textures, update their contents, and execute the graph again without rebuilding
its pipelines. Compilation and submission run on the native worker.

Flutter plugins can use the same API through `context.resources`,
`context.shaders` and `context.graphs` with `SceneRuntime.nativeMetal()` or
`SceneRuntime.nativeAndroid()`. Those services run on the presenter's own device
and native queue. You do not need a second offscreen backend.

Try the complete example from `packages/gpu3d_native`:

```sh
fvm dart run example/render_graph.dart /tmp/native-graph.png
```

It computes a 256 by 256 heatmap, samples it in a full-screen quad and saves a PNG
through explicit readback. The graph keeps both passes on the GPU. After closing
its owners, the example reports zero resource bytes and cached pipelines on the
verified devices.

## Describe passes

Compile your [WGSL programs](shader-compilation.md) and allocate textures through
a resource scope on the same backend. A compute output needs
`TextureUsage.storage`; add `TextureUsage.sampled` when another pass samples it.
Storage textures use linear `TextureFormat.rgba8Unorm`.

Given the example's programs and textures, you build the graph like this:

```dart
final graph = RenderGraph()
  ..addCompute(ComputePassDescriptor(
    name: 'heatmap.update',
    program: compute,
    workgroups: const Workgroups(32, 32),
    bindings: ShaderBindings([TextureBinding.storage(0, density)]),
    writes: [density],
  ))
  ..addRender(RenderPassDescriptor(
    name: 'heatmap.display',
    program: render,
    vertexCount: 6,
    color: ColorAttachment(image),
    bindings: ShaderBindings([
      TextureBinding.sampled(0, density),
      SamplerBinding(1),
    ]),
    reads: [density],
    writes: [image],
  ));
final compiler = backend.createGraphCompiler(label: 'heatmap');
final compiled = await compiler.compile(graph.describe(label: 'heatmap'));
final stats = await compiled.execute();
```

`Workgroups` gives dispatch counts, separate from the shader's workgroup size.
Here, 32 groups with 8 invocations along each axis cover 256 pixels. Your shader
must handle out-of-range invocations when the texture size isn't an exact multiple.

Each registration returns a `Registration` you can dispose. `describe()` captures
an immutable candidate, so later registration edits cannot change a running graph.
You can also construct `GraphDescription` directly.

## Access and ordering

Declare the resources each pass reads and writes. These lists must match its
typed bindings and color attachment exactly. Use `BufferBinding.uniform`,
`storageRead` or `storageReadWrite` for buffers. Storage texture bindings are
write-only. A loaded color attachment counts as both a read and a write.

Add externally initialized resources with `graph.importResource(resource)` or
`GraphDescription(inputs: [...])`. You are responsible for their contents before
each execution. A read-write storage buffer also needs an input declaration or an
earlier writer, even when your current shader overwrites every element.

The compiler orders producers before consumers and accepts a producer registered
after its first consumer. Multiple writers retain registration order. Reads use
the nearest preceding writer, or an imported input; without either, the first
later writer supplies the dependency. You can add ordering constraints with
`after: {'pass.name'}`. Conflicting constraints report a labeled cycle.

Hazards are tracked for whole allocations. Two retained references to the same
texture still alias, including when they select different mips. Multiple read-only
bindings are allowed; a writable allocation cannot occupy another binding or
attachment in the same pass. Discarded attachments cannot feed later reads until
another pass writes them. `compiled.lifetimes` reports first and last use positions
in `compiled.passNames`; it does not enable transient memory aliasing.

Binding visibility defaults to compute for compute passes, vertex and fragment
for render reads, and fragment for render writes. Set `visibility` when you need
a narrower layout. Native pipeline validation checks the layout against WGSL,
including buffer sizes, entry point stages and target formats.

## Replace and close

Await one compilation before starting the next on that compiler. A failed
candidate leaves `compiler.active` usable and throws `GraphException`, with a
typed code, pass name and resource label where available. On success, the new
graph becomes active and the previous graph stops accepting executions. The
compile future waits for its accepted executions and cleanup before returning.

Graphs retain their programs and resources independently of the scopes that
created them. You can close those author scopes after compilation; keep a separate
resource reference if you still need uploads or readback. Uniform updates affect
the next execution without recompilation.

`compiler.close()` stops new work immediately, drains accepted requests and
releases the graph. Await it to receive any collected retirement errors.
`execute()` completes after the submitted GPU work finishes.
`backend.close()` also closes its graph compilers. Pipelines share a weak cache
on the device, keyed by module, binding layout, entry points and target format.
Use `backend.graphStats()` for live graph and pipeline counts. Description bytes
are admission accounting, not measured driver memory.

## Plugin ownership

Inside a `ScenePlugin`, use `context.resources`, `context.shaders` and
`context.graphs` to allocate resources, compile programs and compile the graph.
Each service is created on first access and belongs to that attachment. You do
not need a native backend reference or a private import.

Declare `scopedResources`, `shaderCompilation` and `renderGraphs` in your plugin's
`requiredFeatures`. Add `compute` and `storageTextures` when your passes need
them. The engine checks those requirements before attachment. Direct access on
an unsupported backend also reports the requesting plugin and missing service.

```dart
// During attach, after preparing programs and resources:
compiled = await context.graphs.compile(graph.describe(label: id));

// During beforeRender, when this plugin needs to update its output:
await compiled.execute();
```

The compiler holds one active graph per attachment. Execution is explicit; these
services do not insert passes into the scene renderer or present graph textures.
Use typed `ServiceKey<T>` values to publish outputs to dependent plugins. A
consumer can retain a published texture in its own `context.resources` scope.

Closing the attachment stops new resource, shader and graph work synchronously.
Accepted work drains before `detach` and backend close. Failed attachment follows
the same cleanup path. Services belonging to sibling attachments stay usable.

The platform bridges serialize GPU commands with scene rendering. They enforce
the same input and response limits as the Dart worker before calling Rust. A
presenter closes GPU owners before destroying its native session, including when
resource cleanup fails. Concurrent cleanup failures are collected together.

If you build a native adapter, `NativeGpuServices.withTransport` supplies the
shared codecs and owner tracking. Its sender accepts a command kind, bytes and
response capacity, returning `NativeGpuReply`. Keep one services instance per
device and await its close before destroying the transport. `NativeGpuBackend`
is the common backend contract with resource, shader and graph statistics.

## Scene composition

Add `sceneColor` and `output` to a `GraphDescription` to process a scene frame.
The native renderer executes `beforeScene`, draws the scene into `sceneColor`,
executes `passes`, then samples `output` into the readback target or native surface.
These stages share one command buffer. Surface presentation needs no CPU readback.

```dart
final compiled = await context.graphs.compile(GraphDescription(
  sceneColor: sceneColor,
  output: finalColor,
  beforeScene: [prepareMaterialTextures],
  passes: [colorTransform, vignette],
));
frameBinding.graph = compiled;
```

`beforeScene` is optional. Use it for compute or procedural render passes that
prepare textures or buffers for a custom mesh material. The mesh sees that work
in the same frame. You can register these passes on a `RenderGraph` with
`stage: FramePassStage.beforeScene`; its default stage remains `afterScene`.
Before-scene passes require a frame graph and cannot read or write `sceneColor`,
even if you list it as an external input. The scene initializes that attachment
at the boundary. Dependencies can reorder passes within either phase, but cannot
move an after-scene producer ahead of a before-scene consumer.

For resource preparation without post-processing, use an empty `passes` list and
set `output` to `sceneColor`. `CompiledGraph.beforeScenePassCount` tells you how
many entries at the start of `passNames` execute before the scene. Statistics
include work in both phases and the final output draw.

Claim `frameBinding = context.frameGraph` during `attach`. You can assign a
replacement in `beforeRender` after compilation succeeds, or set `graph = null`
to disable effects. Closing the attachment clears the binding. Only one plugin
owns final composition for a view; cooperating plugins can share a pass builder
through a typed service. This binding does not own the graph's compiler.

Both textures need one mip and dimensions equal to the physical frame size.
The scene texture needs render-attachment usage, and the final output needs
sampled usage. Declare the usages your effect bindings need too. Scene color is
initialized after the before-scene phase; output must remain initialized after the
last pass. Texture formats handle linear/sRGB conversion, including the final
native target. Current formats are RGBA8, so HDR effects need a later format profile.

Advanced callers can pass `graph:` to `FrameSubmission.capture` or
`SceneEngine.renderFrame`. An explicit graph overrides the plugin selection for
that frame. The backend must advertise `frameGraphs`. A frame graph rejects
standalone `execute()`, wrong devices and mismatched sizes; compile matching
resources before rendering a resized frame. You can group candidate textures in
`context.resources.createChild()` and close their author references after
compilation. Temporal history management remains pending.

`FrameStats.drawCalls` and `triangles` include effect draws and the terminal
full-screen draw. `computeDispatches` counts compute passes. Native adapters use
`CompiledGraph.submitFrame` to validate the device and hold graph ownership until
the frame settles. `NativeGpuServices.submitFrame` provides its native packet
encoding for platform adapters.

Lifetime intervals use `beforeScenePassCount - 1` for the implicit scene write
at the boundary and `passNames.length` for the terminal output read. Existing
postprocess-only graphs still use `-1` for the scene write. Explicit passes keep
their zero-based indices. These are conservative diagnostic intervals, not
permission to alias allocations. Graph ownership lasts through GPU completion.

Run `fvm dart run example/frame_graph.dart /tmp/native-frame-graph.png` from
`packages/gpu3d_native`. It renders three meshes, rotates their color channels in
compute, then adds a vignette in a render pass.

The separate [shader lab effects package](../../examples/shader_lab/effects_plugin/README.md)
shows a complete spatial plugin with exposure, saturation and vignette controls.
It uses public core imports, replaces textures on resize, publishes a typed
control service and offers explicit rejection or bypass for unsupported adapters.
The [Flutter demo](../../examples/shader_lab/README.md) runs those passes on its
presenter's native device. Uniform edits reuse pipelines.

## Current profile

The backend advertises `renderGraphs`, `compute` and `storageTextures`. The
implemented profile supports 2D RGBA8 linear/sRGB targets with one sample, a single
color attachment and procedural triangle-list draws using vertex/instance indices.
There are no graph vertex buffers, depth attachments or blend controls yet.

You can use up to 128 passes and 1024 resources per graph, 64 bindings per pass,
four bind groups and slots 0 through 15 in each group. Buffer offsets require
256-byte alignment; sizes require four-byte alignment and must satisfy the
shader's layout and device limits. Native admission allows 32 live graphs and
16 MiB of description storage per device. Labels have a 1024-byte UTF-8 limit.

This profile supports explicit resource graphs, before/after-scene composition
and [custom mesh materials](shader-materials.md). Automatic pass registration and
history resources remain in plan 03. The effects example owns its resize policy
using child scopes.
Graph execution is verified on macOS Metal and Pixel Vulkan; see
[verification](../verification.md). Other
platforms have no graph qualification yet.
