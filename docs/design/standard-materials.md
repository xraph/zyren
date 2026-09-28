# Standard materials and direct lights

You can render metallic/roughness materials with directional, point and spot
lights through the native backend. Import `gpu3d/gpu3d.dart` for Dart or
`flutter_gpu3d/flutter_gpu3d.dart` for Flutter. Geospatial is not required.

```dart
final scene = Scene()..background = const Color3(.02, .02, .02);
final surface = StandardMaterial(
  baseColor: Color3.hex(0xd4a441),
  metallic: .8,
  roughness: .3,
);
final sphere = scene.add(Mesh(SphereGeometry(), surface));
final sun = scene.add(DirectionalLight(intensity: 3));
sun.rotateY(.5);
final fill = scene.add(PointLight(intensity: 4, range: 10));
fill.position = const Vec3(-3, 1, 3);

// Materials are immutable. Assign a replacement to schedule a frame.
sphere.material = surface.copyWith(roughness: .65);
// Lights are scene objects. Property edits also schedule a frame.
sun.intensity = 2;
```

For Flutter, select `SceneRuntime.nativeMetal()` on Apple platforms or
`SceneRuntime.nativeAndroid()` on Android. These presenters advertise
`RenderFeature.standardMaterials`. The explicit readback `NativeBackend` does
too. `SceneEngine` rejects visible standard materials on adapters that lack this
feature before it submits a frame. Legacy `NativeRenderer` adapters do not
advertise this material profile.
The legacy `Scene.snapshot` serializer rejects visible standard materials or
punctual lights. Use `FrameSubmission.capture` to retain their lighting data.

## Material parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `baseColor` | Linear white | Diffuse color for dielectrics, reflectance color for metals |
| `baseColorMap` | None | Existing `TextureMap`, including its sampler and mip policy |
| `metallic` | `0` | Finite value in `[0, 1]` |
| `roughness` | `1` | Finite perceptual roughness in `[0, 1]` |
| `emissive` | Linear black | Emission color, independent of scene lights |
| `emissiveIntensity` | `1` | Finite multiplier in `[0, 1e12]` |

The material also accepts the shared `side`, `alphaMode`, `opacity`,
`alphaCutoff`, `depthTest` and `depthWrite` settings. `copyWith` preserves omitted
values; `clearBaseColorMap: true` removes a map. Base color and emission use
linear RGB. `Color3.hex` converts sRGB for you. The texture descriptor controls
image color space.

Shading uses GGX, height-correlated Smith visibility and Schlick Fresnel with
dielectric reflectance `0.04`. The shader squares perceptual roughness and floors
that result at `0.002025` to keep a zero-roughness highlight finite. Metals have
no diffuse contribution. A black metal with zero emission stays black.

Standard materials use the scene's explicit light objects. The compatibility
`Scene.ambient` and `Scene.lightDirection` settings do not supply extra energy
to this material. Without lights or emission, it renders black.

Opaque and masked materials write depth by default. Blended materials follow
the existing sorted transparency path and its automatic depth-write policy.
Sorting cannot resolve every intersecting transparent surface. See the
[scene alpha contract](scene-alpha.md) for captures and compositor output.

## Light objects

| Type | Intensity unit | Position and direction |
| --- | --- | --- |
| `DirectionalLight` | Lux | Emits along local `-Z`; translation does not affect illumination |
| `PointLight` | Candela | Emits in all directions from its world position |
| `SpotLight` | Candela | Emits from its position along local `-Z` within its cone |

Each light has linear `color`, `intensity`, visibility and the usual scene
transform. Intensity is finite in `[0, 1e12]`; its default is `1`. Lights inherit
parent transforms and visibility. The current native limit is 16 visible lights,
reported through `DeviceLimits.maxPunctualLights`. Hiding a parent hides its
lights too. Exceeding the limit fails explicitly.

Point and spot lights use inverse-square attenuation. `range: null` leaves the
range unbounded. A finite range is in metres, must be in `(0, 1e12]`, and fades to
zero using `max(1 - (distance / range)^4, 0)`. The shader floors squared distance
at `1e-6` square metres to bound intensity at the light's origin. Transform scale
does not change range or intensity.

```dart
final spot = scene.add(SpotLight(
  intensity: 8,
  range: 12,
  innerConeAngle: .2,
  outerConeAngle: .5,
));
spot.position = const Vec3(2, 3, 4);
spot.lookAt(const Vec3(0, 0, 0));
spot.setCone(innerConeAngle: .1, outerConeAngle: .4);
```

Cone angles are radians, with `0 <= inner < outer <= pi / 2`. `setCone` validates
the pair before applying either value. `lookAt` aims the emitting `-Z` axis at a
target in parent coordinates. Angular attenuation interpolates the cosines and
squares the result. Very narrow cones whose cosines coincide in float32 retain
full intensity at their representable centre and zero outside it.

Frame capture freezes light values. Positions subtract the camera origin before
float32 encoding. Directions use the transform's basis directly, so a large
translation cannot erase the direction through subtraction.

## Native transport and ownership

Binary scene opcode 19 extends opcode 18 with a light table after background
alpha. A `u32` count precedes each entry's `u32` kind (`0` directional, `1` point,
`2` spot), then float32 color RGB, intensity, position XYZ, direction XYZ, range,
inner cosine and outer cosine. Zero range means unbounded. Each mesh update adds
a `u32` standard-material flag after sidedness, followed by metallic, roughness
and emissive RGB when set. Older opcodes retain their existing layouts.

Native admission rejects malformed flags, truncated tables, excess lights and
nonfinite or out-of-range parameters before drawing. Material changes participate
in scene deltas. Updating a light or material parameter does not upload the
geometry or image again; per-frame uniforms still update. All standard draws in
one frame share one light uniform buffer. Custom mesh shaders keep their existing
uniform prefix and binding layout.

## Scope and examples

This profile renders direct lighting to the existing RGBA8 scene target. Values
above the target's range clamp. HDR accumulation, tone mapping, normal/ORM and
emissive textures, image-based lighting, hemisphere lights and shadows remain
Task 5 work. Standard glTF material conversion remains gated on that broader
profile and its reference fixtures.

Run the [Flutter PBR lab](../../examples/shader_lab/README.md) for a sphere grid
and light controls. The standalone `gpu3d_native/example/pbr.dart` renders a PNG
through explicit readback for inspection.

The material equations and light conventions follow the
[glTF material specification](https://github.com/KhronosGroup/glTF/blob/main/specification/2.0/Specification.adoc#materials)
and [KHR_lights_punctual](https://github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Khronos/KHR_lights_punctual).
Supporting these equations does not establish glTF extension support. See
[verification](../verification.md) for the tests and devices actually run.
