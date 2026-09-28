# Delivery milestones

The core target is a general Dart 3D library with Three.js-level capability on
native platforms. Geospatial is one optional plugin, alongside future loaders,
controls and effects. Earth-specific behavior must not become a dependency of
ordinary 3D scenes.

The initial native renderer and plugin host establish the API and build path.
You can use the example to evaluate those decisions. Production use needs the
remaining renderer and platform work below.

The detailed [implementation program](superpowers/plans/2026-09-26-native-3d-program.md)
breaks this work into API/DX, native presentation, general rendering, and
geospatial/release plans. It includes exact file responsibilities, interfaces,
failure tests and commit boundaries. The [proposed public API](design/native-3d-api.md)
defines ownership and application workflows before those changes land.

## Core capability target

| Area | Implemented now | Required for the target |
| --- | --- | --- |
| Scene and maths | Object hierarchy, transforms, perspective camera, double precision positions | Orthographic cameras, layers, bounds, raycasting, spatial queries and frustum culling |
| Geometry | Versioned dynamic attributes, uint16/uint32 indices, UVs, box/sphere, portable lines and points | Native tangent/color/skinning bindings, joined/dashed strokes, instancing and morph targets |
| Materials and lighting | Diffuse/unlit materials, color textures, samplers, linear-light mipmaps, alpha modes, depth and draw order | PBR, multiple light types, shadows, environment maps, transparent canvas composition and HDR color output |
| Animation | Frame hooks | Clips, tracks, interpolation, mixers and skeletal animation |
| Assets | Typed scoped loading, shared in-flight decoding, bundle/file/HTTP sources and bounded native PNG/JPEG decoding | glTF models, worker parsing, extension fixtures and compressed textures through loader plugins |
| Rendering | Native GPU pipelines, explicit RGBA output, opt-in Metal views and Android Vulkan shared textures | Render graph, public shader/material extensions, compute, offscreen passes, HDR, postprocessing and broader native surface qualification |
| Extensibility | Dependency-ordered plugins, typed services, replaceable renderer/presenter and scoped versioned GPU resources | Pass descriptors and native shader extensions through the public API |
| Developer tools | Runnable example, capability checks and validation errors | Picking tools, statistics, profiling, context/device recovery and performance fixtures |

Keep shader, texture and render-pass primitives in the core. The geospatial
plugin should express atmosphere and clouds through those public primitives.
Do not add a geospatial-only rendering path to bypass missing core features.

## Delivery order

1. API and native presentation: extract the pure Dart core, establish controller
   ownership and observable scene updates, then replace RGBA readback with shared
   GPU textures. Verify
   resizing, background/resume, Flutter engine detach, device loss and multiple
   viewports on physical iOS/Android devices, macOS and Windows. Measure frame
   latency, CPU copies and GPU memory with representative scenes.
2. General 3D resources: texture/sampler ownership, glTF 2.0 assets, PBR materials,
   HDR output, image-based lighting, instancing, culling, picking, animation and
   skeletal meshes. Define resource disposal and asynchronous loading contracts
   before adding loaders.
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
