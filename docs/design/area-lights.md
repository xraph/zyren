# Rectangular area lights

Use `RectAreaLight` to light standard or physical materials from a finite emitter:

```dart
scene.add(RectAreaLight(width: 2, height: 1, intensity: 4)
  ..position = const Vec3(0, 3, 2)
  ..lookAt(Vec3.zero));
```

The local rectangle faces -Z. Width and height use scene metres before the world
transform; intensity is luminance in cd/m². Scaling the rectangle changes its
emitting area while preserving luminance. Parent transforms can rotate, scale or
shear it. Camera-relative coordinates keep distant scene origins out of shader
arithmetic. Visibility and camera layers apply before the four-light limit.

The renderer integrates diffuse illumination over the clipped polygon. GGX
specular and clearcoat use Linearly Transformed Cosines (LTC), including a stable
basis at normal incidence. The 64 × 64 matrix and amplitude tables come from
Three.js r180 and the original LTC fit. Sheen uses its directional-albedo fit.
Anisotropy uses 8 × 8 Gauss-Legendre quadrature of the physical BRDF, so tangent
orientation still affects the highlight. This costs more than the isotropic LTC
path. A very narrow anisotropic lobe under a large nearby emitter can need more
samples than this bounded approximation provides.

Enable shadows with `shadow: AreaShadow()` and set `castShadow` and
`receiveShadow` on the relevant meshes. Four emitter regions each use a six-face
cube projection, then shade their share of the rectangle with their own
visibility. This gives bounded partial occlusion, with four spatial samples and
PCF at each sample. You can see sampling bands in wide penumbras; this is not a
continuous visibility integral. Moving or resizing the emitter refreshes its
shadow views. Add visible geometry separately if you want to see the emitter.
Use `RenderFeature.areaLighting` and `DeviceLimits.maxAreaLights` when selecting a
backend. Invalid or collapsed rectangles fail before GPU submission.

The tables occupy 128 KiB per native renderer and remain for its lifetime. They
are fixed renderer data, outside scoped-resource counters. Manual bilinear loads
avoid requiring filterable float32 textures. Lighting data is a bounded uniform buffer. Shadowed lights share a 16 MiB
atlas per view, subject to the existing device atlas budget. `AreaShadow` defaults
to 128 pixels per face; four lights use 96 faces and fit the atlas. Increasing
resolution can exceed the shared pixel budget and fails before allocation.
See [shadow settings and ownership](shadows.md).

Metal tests compare diffuse pixels to an independent surface integral and glossy
pixels to a numerical GGX reference. They also cover live dimensions, back-face
rejection, color, clearcoat, sheen, anisotropic rotation, HDR/MSAA and removal of
scene resources. Other native devices still need qualification.

Reference: Eric Heitz, Jonathan Dupuy, Stephen Hill and David Neubelt,
*Real-Time Polygonal-Light Shading with Linearly Transformed Cosines*,
ACM Transactions on Graphics 35(4), 2016.
[Project and paper](https://eheitzresearch.wordpress.com/415-2/).
See the [table license](../../packages/zyren_native/native/src/renderer/ltc/LICENSE)
and [provenance](../../packages/zyren_native/native/src/renderer/ltc/README.md).

Shadow bias uses the face-oriented geometric normal. Your normal map still drives
the material's lighting, but it does not move shadow lookups. Rotating the camera
reuses unchanged area depth views. Camera translation changes the renderer's
relative-coordinate projections and may redraw all 24 views per shadowed area;
that work is included in the native benchmark. Atlas residency stays fixed.
