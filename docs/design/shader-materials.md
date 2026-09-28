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

Choose the attributes your shader reads:

| `MeshVertexLayout` | Vertex locations |
| --- | --- |
| `positionNormal` | Position 0, normal 1 |
| `positionNormalUv` | Adds UV0 at 2 and UV1 at 3 |
| `positionNormalUvTangent` | Adds tangent XYZW at 4 |
| `positionNormalColor` | Position 0, normal 1, color RGBA at 5 |
| `positionNormalUvColor` | Position, normal, both UVs and color |
| `positionNormalUvTangentColor` | All attributes above |

Position and normal use float32 triples; UVs use pairs; tangent and color use
four components. A UV layout requires at least one UV set, with the missing
channel filled with zeros. Tangent and color layouts require those attributes
on the geometry. Missing data rejects the frame before drawing.

Vertex and fragment entry names default to `vertex` and `fragment`, with named
arguments for overrides.

Group 0 belongs to the engine. Include `MeshShaderInterface.wgsl` in your source
to declare its uniform layout. It exposes MVP, model, normal and view-projection
matrices, material color/alpha, light direction/ambient and viewport dimensions.
Matrices use the scene's camera-relative world coordinates. Shader diagnostics
refer to this expanded source, including the prelude.

Use `ShaderBindings` for groups 1 through 3. Deformed programs reserve group 2
for engine buffers, leaving groups 1 and 3 for your resources. Uniform buffers,
read-only storage buffers, sampled textures and samplers use the same validation
as render graphs:

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
You can populate those textures or buffers with `GraphDescription.beforeScene`
passes before a material reads them in that frame. The engine's group-0 uniform
size is part of pipeline validation, so an oversized declaration fails before
the program is published.

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

## Instancing, skinning and morphs

Pass a `geometry` profile when you compile the program. The default is `rigid`.

| `MeshShaderGeometry` | Required mesh data |
| --- | --- |
| `rigid` | An ordinary mesh with no skin or morph pose |
| `instanced` | An `InstancedMesh` with no deformation pose |
| `deformed` | A `SkinnedMesh` or an ordinary mesh with morph targets |
| `deformedInstanced` | An `InstancedMesh` with a shared morph pose |

You can reuse a compiled program across meshes with the same profile and vertex
layout. Both Dart capture and native preparation reject mismatches. Compile
another program when you need another profile; instances of that profile share
the compiled module and native pipeline cache.

For skinning and morph targets, include `MeshShaderInterface.deformation` and
pass the indexed vertex ID to `deform_vertex`. This uses the same WGSL kernel as
ordinary materials:

```dart
final program = await context.shaders.compileMesh(ShaderSource.wgsl('''
${MeshShaderInterface.wgsl}
${MeshShaderInterface.deformation}
@vertex fn vertex(@builtin(vertex_index) index: u32,
    @location(0) position: vec3<f32>, @location(1) normal: vec3<f32>)
    -> @builtin(position) vec4<f32> {
  let d = deform_vertex(index, position, normal, vec4(1., 0., 0., 1.));
  return mesh.mvp * vec4(d.position, 1.);
}
@fragment fn fragment() -> @location(0) vec4<f32> {
  return meshColor(vec4(.1, .8, .3, 1.));
}
'''), geometry: MeshShaderGeometry.deformed);
```

The result contains local `position`, `normal` and `tangent`. If you use tangent
shading, select a tangent vertex layout and supply its authored XYZW value.
Morph deltas apply first, followed by normalized skin weights and the joint
palette. Pose buffers use the existing geometry and resource budgets.

For instancing, include `MeshShaderInterface.instancing` and accept an
`instance: MeshInstanceInput` vertex argument. Its locations 6 through 12 carry
the instance matrix, inverse-transpose normal matrix and orientation sign:

```wgsl
// After deformation, when present:
let localPosition = meshInstanceMatrix(instance) * vec4(position, 1.);
let localNormal = meshInstanceNormalMatrix(instance) * normal;
let clipPosition = mesh.mvp * localPosition;
let worldNormal = (mesh.normalMatrix * vec4(localNormal, 0.)).xyz;
```

Transform tangent XYZ with `meshInstanceMatrix` using a zero W, then with
`mesh.model`. Multiply tangent handedness by `instance.normal0.w` and the sign
of the model matrix determinant. Pass the instance orientation to the fragment
stage using a flat-interpolated varying and call
`meshInstanceFront(frontFacing, orientation)` there. It applies the material's
side setting and returns the oriented facing value for your lighting.

Instanced pipelines disable hardware culling because one draw can contain both
mirrored and unmirrored instances. If you omit the fragment helper, your shader
owns that face policy. Model winding is still handled by the native pipeline.

Geometry and shader bindings stay resident across pose edits. Updating a shared
morph pose uploads its pose buffer; changing one instance transform updates
that instance range. Captured frames keep their original pose and transforms.
Custom shader shadow passes and separate skeletal palettes per instance remain
unsupported. Custom vertex offsets beyond the supplied deformation need matching
application bounds; they cannot be inferred from arbitrary WGSL.

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
It selects the mesh's geometry profile when attached. Run the animated material
demo from `examples/shader_lab` with `flutter run -d DEVICE_ID -t lib/geometry.dart`
to change the skinned pose, shared morph width and stripe uniforms independently.
