# Opaque scene inputs for custom meshes

Opt your mesh program into `MeshSceneInputs.opaqueColorDepth` when its fragment
shader needs the current view's opaque linear HDR color and depth. You can use
this for refraction, depth fades and surface effects. Check
`RenderFeature.meshSceneInputs` on your backend before installing the material.

```dart
final program = await shaders.compileMesh(
  ShaderSource.wgsl(source),
  sceneInputs: MeshSceneInputs.opaqueColorDepth,
);
final material = ShaderMaterial(program);
```

The material compiler accepts the same option:

```dart
final program = await shaders.compile(ShaderSource.wgsl(source));
final material = await materials.compile(
  MeshShaderDescriptor(
    program: program,
    sceneInputs: MeshSceneInputs.opaqueColorDepth,
  ),
);
```

Include `MeshShaderInterface.wgsl` and `MeshShaderInterface.sceneInputs` in your
WGSL source. Group zero belongs to the engine. Opting into scene inputs reserves
group three as well; user bindings in that group fail validation. Deformation
still reserves group two when selected. Programs without scene inputs keep their
existing binding layout.

The scene-input prelude provides fragment-stage helpers:

| Helper | Result |
| --- | --- |
| `meshSceneColor(pixel)` | Linear RGBA16F opaque radiance, including values above one |
| `meshSceneDepth(pixel)` | Resolved WebGPU depth in `[0, 1]` |
| `meshSceneHasSurface(depth)` | Whether depth differs from the current clear value |
| `meshScenePosition(pixel, depth)` | Position in camera-relative world coordinates |

Pixels use the top-left origin and physical viewport dimensions. Loads map those coordinates to the capture grid, then floor
and clamp to that grid. Position reconstruction uses the loaded
pixel's center and the current inverse view-projection matrix, including temporal
jitter. Test `meshSceneHasSurface` before reconstructing a position. Clear depth
does not describe a surface. `meshScene.viewport` contains width, height and their
reciprocals; `meshScene.depthInfo.xy` contains clear depth and the reversed-depth
flag. Both perspective and orthographic cameras are supported.

The capture runs before consuming surfaces. It excludes every scene-input
consumer, physical transmission mesh and alpha-blended mesh. Alpha-mask geometry
keeps its cutout behavior. Transparent foregrounds still participate in the final
scene pass. They cannot be refracted through this opaque input. Captured radiance
has not passed through the final display tone mapping; return linear HDR from
your shader so the renderer applies that pipeline once.

Capture textures belong to the frame renderer. The API exposes shader bindings,
not reusable resource handles. View changes and resize refresh bindings, and
retirement clears cached references before releasing old targets. Failed target
admission preserves the previous allocation for a corrected frame.

One and four samples are supported. With four samples, color resolves by
averaging and depth selects the nearest covered sample according to the active
depth convention. The capture allowance is 128 MiB, including retained and
candidate allocations, with a 64 MiB limit for resolved color. Four-sample color
and depth attachments count in that allowance. These are logical texture bytes,
not a measurement of physical GPU residency.

Native macOS fixtures cover both compiler APIs, HDR capture with HDR and SDR
outputs, standard/reversed depth, perspective/orthographic cameras, MSAA, live
updates, transparency, view changes, resize and failed admission. Android,
iOS and Windows device qualification remains open. The feature is generic;
these checks do not establish water optics or visual quality.


Set `scene.renderSettings.opaqueCaptureScale` to a value in `[0.5, 1]` to
reduce the native opaque capture resolution. Check
`RenderFeature.scaledOpaqueCapture` first. The default is one. Width and height
round up independently; half scale uses one quarter of the capture pixels on an
even-sized view. The main view stays at its original size. Transmission and
custom scene-input surfaces share this capture, including its reduced detail.

Shader helpers still accept full-view pixel coordinates. Depth reconstruction
uses the center of the selected capture texel. MSAA color and depth resolve at
the scaled size. Main-pass opaque reuse is disabled at reduced scale because its
color and depth would otherwise change the final view's resolution.

The native fixture checks scales 1, 0.75 and 0.5 across view changes, depth modes,
compiler paths and sample counts. Reported attachment bytes follow the rounded
capture dimensions. Glass transmission also checks reduced capture with an odd
31-pixel view. This reduces attachment payload and capture raster work; it is not
a measured frame-rate guarantee.
