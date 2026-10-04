# W6 native water optics

The native material now renders displaced spectral water with filtered normals,
Fresnel reflection, GGX sunlight, depth-aware refraction and homogeneous water
attenuation/scattering. Screen-space reflections use the current opaque capture
and blend misses to the environment. Planar reflections remain unsupported.

## Evidence

Thirteen rendering tests passed on macOS Metal using the FVM Flutter 3.47.5 SDK:

```sh
cd packages/zyren_geospatial_ocean
RUN_NATIVE_GPU=1 /Users/rexraphael/fvm/versions/3.47.5/bin/dart test test/rendering --concurrency=1
```

- Numeric Fresnel tests cover normal incidence, Brewster incidence, reciprocity,
  total internal reflection and invalid input. Beer-Lambert checks cover zero
  distance, composed segments and bounded homogeneous source integration.
- Controlled native pixels match expected wavelength-dependent absorption and
  Fresnel reflection. Foreground markers survive; rigid and morphed geometry
  pass with standard and reversed depth.
- Nearby red geometry reflects through current scene depth. Hiding it clears the
  reflection on the next frame for both depth conventions.
- Native convolved HDR environments remain usable after their original scope
  closes. Shared atmosphere LUTs produce distinct day/night water lighting.
- The native material field matches an independently interpolated spectral
  reference at both poles, a two-chart overlap and a three-chart corner, within
  `2e-5` metres for displacement and `2e-5` for normal-vector difference.
- CPU control stencils preserve displaced coarse edges during refinement and
  coarsening. Native offsets plus actual float32 morphed mesh vertices have a
  maximum shared-edge gap of `0.0000018664299242549027` m on the 32 m sphere fixture.
  The same fixture renders all morph states through the native scene path.
- Packed mip checks cover field means, slope moments, immutable times, stale
  source rejection and byte admission. Resources return to zero after owned
  scopes retire and the cleared scene is submitted.

The existing twelve native mesh, material and transmission fixtures also passed
from `packages/zyren_native` after concurrent renderer changes. Package analysis
and boundary checking passed.

Workspace-root native tests briefly failed because the launch had no
`zyren_native` asset mapping. Package-local execution includes the declared native
dependency and passed. No renderer implementation was changed for that failure.

## Captures

The optical fixture uses one 256² canonical/render band, a tessellated local
surface, shared atmosphere tables, four-sample coverage and ACES Filmic display
mapping at 480 x 320. The floor and colored objects are deliberately unlit inputs
for observing water transport. They therefore remain emissive-looking at night.
The rectangular floor is test geometry, not coastline data.

| Fixed scene | Capture |
| --- | --- |
| Low sun, roughness .07 | [Image](ocean-optics/sun-low.png) |
| High sun, roughness .07 | [Image](ocean-optics/sun-high.png) |
| Low sun, roughness .45 | [Image](ocean-optics/rough.png) |
| Night atmosphere | [Image](ocean-optics/night.png) |
| Isolated current-depth reflection | [Image](ocean-optics/reflection-standard.png) |
| Reversed-depth reflection | [Image](ocean-optics/reflection-reversed.png) |

Set `OCEAN_CAPTURE_DIR` to an absolute output directory when running the rendering
suite to regenerate PPM captures. The saved PNGs were converted from those native
readbacks and inspected. These are optical regression scenes, not professional
visual acceptance or an FPS benchmark.

## Limits

Wave atlases use native compute and RGBA32F sampled textures. An initial six-storage-
buffer design exceeded this native path's four-buffer stage limit, including two
buffers reserved for deformation. Texture packing satisfies that device limit
without relaxing core capabilities. Logical admission includes the packed texture
payload, temporary packing buffer and caller-declared retained candidates.

Screen-space reflections cannot see off-screen or transparent geometry. Confidence
uses current depth, edges and thickness; there is no temporal reconstruction.
Rough scene hits fade to environment radiance. Atmospheric rough reflection uses
five directional samples, and the volume term is a homogeneous single-source
approximation. Missing light-path shadows are not presented as simulated shadows.

Underwater integration, interactions, buoyancy, effective quality profiles and
integrated Earth coverage are pending. The small-sphere seam result does not
establish a global error bound. No mobile/Windows run, physical GPU residency,
whole-scene frame budget or professional visual acceptance is claimed.

Numerical references: [PBRT dielectric reflection](https://www.pbr-book.org/4ed/Reflection_Models/Dielectric_BSDF)
and [homogeneous transmittance](https://www.pbr-book.org/4ed/Volume_Scattering/Transmittance).
