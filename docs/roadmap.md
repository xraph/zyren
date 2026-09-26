# Delivery milestones

The initial native renderer and geodetic core establish the API and build path.
You can use the example to evaluate those decisions. Production use needs the
remaining renderer and platform work below.

1. Native presentation: replace RGBA readback with shared GPU textures. Verify
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
