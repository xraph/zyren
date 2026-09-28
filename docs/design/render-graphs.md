# Run native shader graphs

Use `NativeBackend.createGraphCompiler()` to run WGSL compute and procedural
render passes on the backend's native device. You can bind scoped buffers and
textures, update their contents, and execute the graph again without rebuilding
its pipelines. Compilation and submission run on the native worker.

Try the complete example from `packages/zyren_native`:

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
Storage textures accept linear RGBA8, RGBA16 float, RGBA32 float and R32 float.
Use `TextureDimension.d3` and `depth` for volumes. The bind layout follows the
texture dimension and format, so your WGSL declaration must match both.

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

## Current profile

The backend advertises `renderGraphs`, `compute` and `storageTextures`. The
implemented profile supports 2D RGBA8 linear/sRGB and floating-point targets with
one sample, a single color attachment and procedural triangle-list draws using
vertex/instance indices. Compute and sampling also support 3D textures. Volumes
have a 256-texel limit per axis and cannot be color attachments. All allocations
share the existing 64 MiB device budget. RGBA16 float supports linear sampling;
RGBA32 float and R32 float require nearest sampling or `textureLoad` in the
portable profile. Automatic mip generation remains limited to 2D RGBA8 images.
There are no graph vertex buffers, depth attachments or blend controls yet.

You can use up to 128 passes and 1024 resources per graph, 64 bindings per pass,
four bind groups and slots 0 through 15 in each group. Buffer offsets require
256-byte alignment; sizes require four-byte alignment and must satisfy the
shader's layout and device limits. Native admission allows 32 live graphs and
16 MiB of description storage per device. Labels have a 1024-byte UTF-8 limit.

Plugins obtain lazy attachment-owned `context.resources`, `context.shaders` and
`context.graphs`. Detachment closes these scopes and drains accepted operations.
Metal and Android native views run their commands on the same native queue and
renderer as scene presentation. Host shutdown drains GPU scopes before destroying
the renderer. The standalone native backend uses the same command adapters.

This profile executes into explicit resource textures. Scene `ShaderMaterial`,
direct platform-view graph composition and resize/history resources remain in
plan 03. Graph execution is verified on
macOS Metal and Pixel Vulkan; see [verification](../verification.md). Other
platforms have no graph qualification yet.
