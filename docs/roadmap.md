# Delivery milestones

The core target is a general Dart 3D library with Three.js-level capability on
native platforms. Geospatial is one optional plugin, alongside future loaders,
controls and effects. Earth-specific behavior must not become a dependency of
ordinary 3D scenes.

The native renderer, navigation and RGB atmosphere have passed the
[current qualification](parity/navigation-renderer-atmosphere-checkpoint.md) on
macOS, Pixel and iPhone. The full source port is incomplete. Use the
[parity matrix](parity/matrix.md) for the remaining source contracts and story
comparisons; platform and performance limits still apply.

The detailed [implementation program](superpowers/plans/2026-09-26-native-3d-program.md)
breaks this work into API/DX, native presentation, general rendering, and
geospatial/release plans. It includes exact file responsibilities, interfaces,
failure tests and commit boundaries. The [proposed public API](design/native-3d-api.md)
defines ownership and application workflows before those changes land.

## Core capability target

| Area | Implemented now | Required for the target |
| --- | --- | --- |
| Scene and maths | Object hierarchy, double precision positions, perspective/orthographic cameras, transitions, bounds and triangle/instance raycasting | Layers, broader spatial queries, frustum/LOD culling and deformed picking |
| Geometry | Dynamic attributes, uint16/uint32 indices, UV0/UV1, tangents, primitives, lines/points and instancing | Skinning, morph targets and joined/dashed strokes |
| Materials and lighting | Metal/roughness PBR and maps, punctual lights, environment convolution, directional/spot shadows, mipmaps and alpha modes | Multiple-scattering PBR, advanced physical materials, area lights and point-light shadows |
| Animation | Frame hooks and optional transform/camera timeline tracks with interpolation and playback | glTF animation import, mixers, skeletal animation, morphs and event tracks |
| Assets | Scoped loading, shared decoding, bundle/file/HTTP sources, PNG/JPEG and standard glTF with unlit/punctual-light extensions | Compressed textures/meshes, further image formats and glTF extensions |
| Rendering | Native Metal/Vulkan presentation, public WGSL graphs/compute, reversed depth, HDR, MSAA/FXAA, bloom and custom effects | Temporal reconstruction, motion vectors, GPU timestamps, indirect draws and wider platform qualification |
| Extensibility | Dependency-ordered plugins, typed services, replaceable backends and scoped resources/shader/graph APIs | Further source shader-node equivalents and capability profiles |
| Developer tools | Picking/selection tools, scene inspection, sampled frame statistics, capability checks and validation errors | GPU timing, broader recovery qualification and representative performance fixtures |

Keep shader, texture and render-pass primitives in the core. The geospatial
plugin should express atmosphere and clouds through those public primitives.
Do not add a geospatial-only rendering path to bypass missing core features.

## Remaining delivery order

1. Extend the [offline terrain/imagery slice](parity/terrain-streaming.md), which
   now uses public core APIs with screen-space-error LOD, bounded requests/caches
   and cancellation. The [reversed-depth fixture](parity/planetary-depth.md) now
   measures surface-to-orbit depth behavior. Add remote terrain formats and the
   separate 3D Tiles loader, then provider adapters and source story configurations. Keep credentials outside the rendering core.
2. Complete atmosphere variants: source LUT loading, automatic material lighting,
   probes/environment adapters, spectral integration and remaining haze overlays.
3. Add volumetric clouds, weather generators, cloud shadows, temporal reconstruction
   and remaining source effects. Check moving cameras and changing weather.
4. Extend the general renderer with animation/skinning/morphs, compressed assets
   and the [material/effect backlog](renderer-capabilities.md#extension-backlog).
5. Compare all upstream stories at fixed cameras, times, assets and exposures.
   Qualify Windows/Linux and broader device recovery, then measure representative
   frame latency, copies and memory use.

Completion means the API, native implementation, tests and example work together.
A successful cross-compile does not establish device compatibility or frame rate.
