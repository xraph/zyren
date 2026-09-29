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

Area lights do not cast shadows in this profile. They illuminate existing
surfaces; add visible geometry separately if you want to see the emitter itself.
Use `RenderFeature.areaLighting` and `DeviceLimits.maxAreaLights` when selecting a
backend. Invalid or collapsed rectangles fail before GPU submission.

The tables occupy 128 KiB per native renderer and remain for its lifetime. They
are fixed renderer data, outside scoped-resource counters. Manual bilinear loads
avoid requiring filterable float32 textures. No allocation scales with the number
of lights; lighting data is a bounded uniform buffer.

Metal tests compare diffuse pixels to an independent surface integral and glossy
pixels to a numerical GGX reference. They also cover live dimensions, back-face
rejection, color, clearcoat, sheen, anisotropic rotation, HDR/MSAA and removal of
scene resources. Other native devices still need qualification.

Reference: Eric Heitz, Jonathan Dupuy, Stephen Hill and David Neubelt,
*Real-Time Polygonal-Light Shading with Linearly Transformed Cosines*,
ACM Transactions on Graphics 35(4), 2016.
[Project and paper](https://eheitzresearch.wordpress.com/415-2/).
See the [table license](../../packages/gpu3d_native/native/src/renderer/ltc/LICENSE)
and [provenance](../../packages/gpu3d_native/native/src/renderer/ltc/README.md).
