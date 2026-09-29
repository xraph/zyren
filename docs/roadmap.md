# Delivery milestones

The core target is a general Dart 3D library with Three.js-level capability on
native platforms. Geospatial is one optional plugin, alongside future loaders,
controls and effects. Earth-specific behavior must not become a dependency of
ordinary 3D scenes.

The native renderer now covers the core feature families below. You can run the
physical-material gallery to exercise glass, area lighting, MSAA, temporal AA and
bloom together. Check the [capability matrix](renderer-capabilities.md) for the
supported combinations and device evidence before choosing a production target.
The [core validation record](core-completion.md) lists the delivered commits,
final test results and remaining qualification limits.

The detailed [implementation program](superpowers/plans/2026-09-26-native-3d-program.md)
breaks this work into API/DX, native presentation, general rendering, and
geospatial/release plans. It includes exact file responsibilities, interfaces,
failure tests and commit boundaries. The [proposed public API](design/native-3d-api.md)
defines ownership and application workflows before those changes land.

## Core capability target

| Area | Implemented now | Required for the target |
| --- | --- | --- |
| Scene and maths | Hierarchies, transforms, perspective/orthographic cameras, layers, bounds, BVH picking, culling and camera framing | Broader reference coverage for complete Three.js parity |
| Geometry | Dynamic attributes, lines/points, curves/tubes, instancing, skinning/morphs, shapes with holes, beveled extrusion and topology helpers | Text, subdivision and CSG |
| Materials and lighting | Standard PBR, IOR/specular, clearcoat, sheen, anisotropy, transmission/volume, iridescence/dispersion, twelve physical maps, punctual/hemisphere/area lights, punctual and area shadows and environment lighting | Nested volumes, continuous emitter visibility and broader device references |
| Animation and controls | Clips, tracks, interpolation, blending, skeletal animation, orbit/trackball/fly controls | Broader mixing and reference gesture coverage |
| Assets | Scoped loading, worker glTF parsing, image decoding, physical extensions and native Draco/meshopt/Basis decoding, BC7/ETC2/ASTC GPU residency | Additional loaders/exporters and decoder qualification on other targets |
| Rendering | Native presentation, shader extensions, compute/render graphs, HDR, MSAA, bloom, spatial AA and motion/depth temporal AA | Temporal motion for custom shaders and line/point primitives, broader native surface qualification |
| Extensibility | Dependency-ordered plugins, typed services, replaceable backend/presenter, public pass descriptors and scoped GPU resources | Keep future plugins on these public contracts |
| Developer tools | Runnable galleries, picking, resource/frame statistics, budget checks, recovery fixtures and AOT benchmarks | Physical-device timing, display pacing, power and thermal measurements |

Keep shader, texture and render-pass primitives in the core. The geospatial
plugin should express atmosphere and clouds through those public primitives.
Do not add a geospatial-only rendering path to bypass missing core features.

## Qualification and plugin work

1. Native presentation: qualify resizing, background/resume, Flutter engine
   detach, device loss and multiple viewports on physical iOS/Android devices
   and Windows. macOS Metal and iOS simulator fixtures pass, but simulator checks
   do not qualify a physical phone. Measure display pacing, CPU copies and GPU
   memory with representative scenes.
2. General 3D breadth: use the implemented material, lighting, geometry, control
   and asset APIs while extending the remaining families in the table. Require
   native reference output and bounded resource cleanup for each addition.
3. Planetary rendering: complete geographic tiling and camera controls, add
   screen-space-error LOD, terrain/imagery streaming, origin rebasing and an
   Earth-scale depth strategy. Keep credentials and network fetching outside
   the rendering core.
4. Atmosphere: port scattering precomputation and evaluation to WGSL, compare
   LUTs numerically and compare native output with the supplied reference.
   Add astronomy fixtures and atmosphere-aware material lighting.
5. Clouds and effects: volumetric ray marching, shadows, temporal history,
   tone mapping and antialiasing. Validate camera cuts, changing weather,
   precision, GPU feature limits and memory use on mobile hardware.

Completion means the API, native implementation, tests and example work together.
A successful cross-compile does not establish device compatibility or frame rate.
