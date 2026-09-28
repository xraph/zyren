# Custom mesh materials

Use `context.shaders.compileMesh` to compile a WGSL vertex and fragment program
for a triangle mesh. Assign the resulting program through `ShaderMaterial`.
The scene renderer supplies transforms, indexed geometry, draw ordering and
raster state. A plugin can shade an object without changing Rust.

```dart
final program = await context.shaders.compileMesh(ShaderSource.wgsl('''
${MeshShaderInterface.wgsl}
@vertex fn vertex(@location(0) position: vec3<f32>)
    -> @builtin(position) vec4<f32> {
  return mesh.mvp * vec4(position, 1.);
}
@fragment fn fragment() -> @location(0) vec4<f32> {
  return meshColor(vec4(.1, .8, .3, 1.));
}
''', label: 'green.wgsl'));
mesh.material = ShaderMaterial(program, side: MaterialSide.front);
```

Declare `RenderFeature.meshShaders`, `shaderCompilation` and `scopedResources`
in your plugin's required features. The native worker, Metal view and Android
view backends support this contract. Other adapters must advertise it before
the engine accepts a scene containing these materials.

## Geometry and bindings

The default `MeshVertexLayout.positionNormal` supplies float32 position and
normal attributes at locations 0 and 1. Choose `positionNormalUv` for UV0 and UV1
at locations 2 and 3. The geometry must contain at least one UV set; the other
channel is zero-filled. Vertex and fragment entry names default to `vertex` and
`fragment`, with named arguments for overrides.

Group 0 belongs to the engine. Include `MeshShaderInterface.wgsl` in your source
to declare its uniform layout. It exposes MVP, model, normal and view-projection
matrices, material color/alpha, light direction/ambient and viewport dimensions.
Matrices use the scene's camera-relative world coordinates. Shader diagnostics
refer to this expanded source, including the prelude.

Use `ShaderBindings` for groups 1 through 3. Uniform buffers, read-only storage
buffers, sampled textures and samplers use the same validation as render graphs:

```dart
final tint = await context.resources.createBuffer(BufferDescriptor(
  size: 16,
  usage: {BufferUsage.uniform, BufferUsage.copyDestination},
));
await context.resources.writeBuffer(tint, Float32List.fromList([1, 0, 0, 1]));
// WGSL: @group(1) @binding(0) var<uniform> tint: vec4<f32>;
final bindings = ShaderBindings([BufferBinding.uniform(0, tint, group: 1)]);
// Pass bindings to compileMesh, then update tint before later frames.
```

Writable bindings are rejected. A material also cannot sample the active scene
color attachment. Post-processing belongs in a frame graph after the scene pass.
Custom material textures use scoped bindings rather than `TextureMap`.

## Color and raster state

Return linear color from the fragment shader. `meshColor(sample)` multiplies by
the material color, applies opacity, discards masked fragments and supplies the
alpha expected by the selected blend mode. Raw WGSL controls its own output;
omitting this helper means implementing those operations yourself.

`ShaderMaterial.copyWith` changes color, opacity, cutoff, sidedness and depth
settings while preserving its program. Native pipeline variants apply culling,
mirrored winding, source-over blending and depth test/write settings. These
variants share the compiled module and binding layout. Uniform updates do not
compile pipelines. The current profile supports triangle meshes and one sample.

## Ownership and failures

A mesh program belongs to its compiler and native device. Views on that device
can share it; independent devices must compile their own. Built-in material
descriptions remain portable. Avoid assigning a device-bound material to a scene
that independent devices render concurrently.

Successful compilation retains the module and bound resources independently of
their author scopes. You may close those scopes while the material remains live.
Close the program explicitly when replacing it, or let its compiler/attachment
close it. Closure stops admission, waits for accepted frames and releases native
ownership. A captured frame cannot start after its program has closed.

Compile a candidate before assigning it. Source errors throw
`ShaderCompilationException`; layout and pipeline errors throw `GraphException`
with the source label. A rejected candidate leaves an existing material usable.
Internal GPU failures require device recreation. The renderer bounds live mesh
programs to 128, owned pipeline variants to 512 and descriptor accounting to
16 MiB per device. `graphStats()` exposes `liveMeshShaders` and `meshPipelines`.

The [shader lab plugin](../../examples/shader_lab/effects_plugin/README.md)
demonstrates a UV stripe material, live uniform changes and restoration of a
borrowed mesh on detach. Its library imports only the public Dart core API.
