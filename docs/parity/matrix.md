# Native port parity matrix

The port is incomplete. You can use this matrix to see the source contract,
the native work it needs, and the evidence required before a row can pass.
The initial renderer and globe demo do not establish atmosphere, cloud, control
or tile-streaming parity.

## Fixed reference

The supplied `three-geospatial-main` directory matches upstream commit
[`b012ad06d858fc035d88aacfd73f092f93c994e4`](https://github.com/takram-design-engineering/three-geospatial/tree/b012ad06d858fc035d88aacfd73f092f93c994e4),
committed May 27, 2026. All 820 file contents match the Git blob hashes from
GitHub's recursive tree, with no missing or extra files. The source directory
has no `.git` metadata, so its name and modification dates alone were not used
to identify the revision.

[The catalog](catalog.md) lists 584 exported declarations across 180 source
modules and 74 story exports across both Storybooks. This includes exported
internal helpers, types and shader nodes, not 584 distinct user features.
[The JSON](inventory.json) retains member names, source lines, re-export
statements, integration imports and file hashes. All package entrypoints,
including WebGPU and R3F, remain in scope. Browser runtime classes become native
rendering contracts or Flutter adapters; their behavior must still be covered.

The hosted Manhattan story was inspected on September 26, 2026. It rendered
photorealistic city tiles and atmospheric haze with AgX exposure 60, lens flare,
sun/sky/transmittance/inscatter controls, altitude/geometric correction and an
orthographic toggle. Its deployed revision is not established by the local
source match. Native comparison has not run.

## Feature coverage

Source names below resolve through the linked catalog at the fixed revision.
`Partial` means useful code exists but the full source contract has not passed.
`Missing` means there is no implemented native equivalent. A passing algorithm
fixture does not pass a GPU or device gate.

| ID | Source capability | Native state | Required implementation and evidence |
| --- | --- | --- | --- |
| G01 | Geodetic, Ellipsoid, surface projection/intersection, ENU/NUE, osculating sphere, horizon normal | Partial: conversion, ray intersection and ENU | Numeric fixtures for every operation, triaxial ellipsoids, poles, subterranean points, center behavior and normalization |
| G02 | Rectangle, TileCoordinate, TilingScheme | Missing | Radian extents, south-origin tile Y, parent/descendant order, dateline behavior, documented upstream quirks |
| G03 | PointOfView, Camera story | Missing | Heading/pitch/roll, clamps, camera extraction and no-hit behavior, round trips at Earth scale |
| G04 | EllipsoidGeometry, QuadGeometry | Partial: indexed ellipsoid without source UV contract | Segments, winding, UVs, normals and native geometry comparisons |
| C01 | OrbitControls in drei/three-stdlib and Three.js addons | Missing: GlobeOrbitPlugin is a different control | Full event replay and camera traces; see [controls](controls.md) |
| C02 | EnvironmentControls, GlobeControls, CameraTransition | Missing | Surface picking, near/far control transitions, inertia, height clearance, projection transitions and touch arbitration |
| C03 | Story keyboard control, location/POV, first-drag height policy, pivot indicator | Missing | Keyboard routing, geographic placement, initial low-LOD stability and screen-sized pivot rendering |
| L01 | ArrayBuffer, TypedArray, DataTexture, EXR/EXR3D and STBN loaders; typed parsers | Missing | Native async transport, cancellation, parser fixtures, dimensional/format checks, typed ownership and failure propagation |
| L02 | Shader includes/unrolling, defines, math/constants, capability helpers | Missing | Native module composition and WGSL equivalents, validation diagnostics; no JavaScript runtime |
| A01 | AtmosphereParameters, density profiles, constants and color matching | Missing | Both legacy and WebGPU defaults/units, parameter updates, spectral integration fixtures |
| A02 | PrecomputedTexturesGenerator/Loader, AtmosphereLUT nodes/textures, Bruneton precompute/runtime | Missing | Native float 2D/3D textures, transmittance/irradiance/scattering/single-Mie/higher-order LUT generation and loading; numeric LUT comparison |
| A03 | SkyMaterial/SkyNode, SunNode, MoonNode, Stars geometry/material/nodes | Missing | Sun/moon disks, lunar orientation and radiance, star data, sky background/backdrop, ground and space views |
| A04 | Celestial directions and ECI/ECEF/moon-fixed transforms | Missing | Astronomy Engine 2.1.19 behavior, UTC/time conventions, sun/moon positions across reference dates |
| A05 | AerialPerspectiveEffect/Node, atmosphere overlays/shadows/masks | Missing | Depth/normal reconstruction, altitude/geometric correction, transmittance and inscatter toggles, backdrop transmission and shadow length |
| A06 | SunDirectionalLight, SkyLightProbe, getSunLightColor, AtmosphereLight/Node, SkyEnvironment | Missing | Direct and indirect lighting, probes/environment, light-source and postprocess paths, object/background consistency |
| A07 | Atmosphere context, runtime/accessors, R3F Atmosphere/Sky/Stars/lights | Missing | Scoped Dart configuration, Flutter lifecycle, date updates, resource replacement and disposal |
| V01 | CloudLayer(s), DensityProfile, quality presets | Missing | Layer channels, heights, density curves, weather coverage, low/medium/high/ultra exact defaults |
| V02 | ProceduralTexture/3DTexture, LocalWeather, CloudShape/Detail, Turbulence | Missing | Native generators, tiling/noise distributions, seed/texture comparisons and supplied assets |
| V03 | CloudsEffect, cloud/shadow passes/materials, cascaded shadow maps | Missing | Primary/secondary ray marches, multiscattering, haze, light shafts, detail/turbulence, cloud/ground/sun lighting, shadow cascades |
| V04 | Cloud temporal resolve/upscale, reprojection, STBN, R3F Clouds | Missing | Motion history, disocclusion, camera cuts, resize, weather changes, frame demand and memory bounds |
| E01 | GeometryPass/Effect, setupMaterials, DepthEffect, NormalEffect | Missing | G-buffer formats, normal/depth debug outputs, material setup and native render-pass integration |
| E02 | LensFlare effects/nodes, downsample thresholds, blur chain | Missing | Ghosts, halo, chromatic effects, occlusion and pixel comparisons |
| E03 | DitheringEffect, createHaldLookupTexture, story color grading/tone mapping/SMAA | Missing | Ordered postprocessing, LUT layout, AgX/Reinhard/Cineon/ACES/linear, exposure and AA |
| E04 | Gaussian/Kawase/mipmap/surface blur, filters | Missing | Kernel/LOD/edge fixtures and native image comparisons |
| E05 | TemporalAntialias, HighpVelocity, ScreenSpaceShadow, CascadedShadowMaps | Missing | Jitter/motion vectors/history, edge cases, cascade stabilization and shadow-length sampling |
| E06 | RenderTarget/Output/Storage texture nodes, sampling/generators/transforms | Missing | General native render graph, compute, texture arrays/3D, typed bindings, hazards and resource retirement |
| T01 | TilesRenderer integration and CameraTransition | Missing | Tileset hierarchy, bounding volumes, transforms, SSE/LOD, ADD/REPLACE, loading queues, caches, cancellation, errors and attribution |
| T02 | GoogleCloudAuth/CesiumIonAuth, GLTFExtensions/Draco, tile compression | Missing | Caller-owned credentials, token refresh, native glTF and compressed meshes/textures, network failures and recovery |
| T03 | Fade, creased normals, material replacement, update-on-change/bundles | Missing | Native fade/material/geometry updates, invalidation and bounded caches; no stale tile resources |
| T04 | Terrain/images, shared tiles, water-area vector overlays, worker helpers | Missing | Raster/vector source mapping, triangulation, texture overlays, water materials and worker cancellation |
| X01 | R3F helpers, examples, Earth, Moon and procedural scene assets | Missing except basic planet | Flutter controllers/widgets and executable native versions of all 74 story cases, compact desktop/mobile controls |

The complete file and declaration inventory is the catch-all scope for helpers
not named individually above. Every implementation commit must link its source
symbols and tests here. Do not silently drop a feature because the source calls
it experimental or uses a browser-specific mechanism.

## Core prerequisites and ownership

This checkout starts at `734fbb9` on `dart-core-api`, which includes `99eb6a1`.
The active SceneRuntime/native Metal integration worktree is read-only to this
port. Hosted presentation and its later adapter must be reused after they are
committed; do not create another bridge or put Earth-specific code into Rust's
generic renderer.

| Gate | Core work | Consumers | Exit evidence |
| --- | --- | --- | --- |
| R1 | Completed hosted SceneView adapter, input and lifecycle | All visual slices | Native frames, pointer routing, resize/suspend/dispose, multiple views |
| R2 | Orthographic camera, rays, bounds, picking, viewport dimensions, key input | Controls, tiles, camera transition | Numerical projections and hit fixtures, widget event replay |
| R3 | Resource handles, samplers, UVs/tangents, 2D/3D/array/float textures, upload and cancellation | Loaders, PBR, atmosphere/clouds | Validation and actual GPU upload/readback, disposal under failure |
| R4 | Extensible materials and WGSL pipelines, typed bindings, depth/normal targets, HDR and color management | Atmosphere/effects | Custom plugin pipeline through public APIs, native pixel comparisons |
| R5 | Render graph, compute, MRT, barriers, mipmaps, temporal history | LUT generation, clouds, effects | Dependency validation, read/write hazards and device capability failures |
| R6 | PBR, multiple lights, shadows, environment lighting, alpha, instancing and glTF extension points | Tile cities and full stories | glTF corpus, lighting fixtures, actual asset rendering |
| R7 | Camera-relative transforms, planetary depth strategy, streaming budgets/culling | Ground-to-space movement | Millimeter local detail, horizon/depth stress cases, stable LOD |
| R8 | Native mobile/desktop packaging and backend presentation | Release | Separate physical iOS/Android, macOS and Windows runtime qualification |

## Implementation sequence

1. Commit the source identity, inventories, control comparison and complete
   dependency plan. Keep the source snapshot unchanged.
2. Port G01-G03 as pure Dart operations. Generate expected values by executing
   the pinned upstream algorithms in a development-only Node workspace; commit
   fixtures and a reproducible generator. Record deliberate API differences.
3. Reuse the committed SceneView adapter. Implement R2 with general camera/input
   contracts, then C01 and C02 in separate focused slices. Prove pointer, wheel,
   touch, cancellation and damping traces before claiming either control matches.
4. Implement R3-R6 as general gpu3d resources and renderer capabilities. Each
   slice needs a non-geospatial example as well as its plugin consumer. Keep
   browser/node shader APIs as reference algorithms, with native WGSL execution.
5. Port loaders, astronomy and LUTs; then sky, stars, lighting and aerial
   perspective. Compare numeric intermediates before final pixels. Cover
   non-geospatial scenes, Moon, ground, cruising altitude, LEO and space.
6. Build the tile loader over the asset/resource APIs, starting with a local
   licensed fixture. Add provider authentication, LOD/caches, glTF/Draco, fades,
   terrain and overlays. Connect the Manhattan and Fuji configurations exactly.
7. Port clouds, all quality presets and procedural generators, then temporal
   resolve, shadows and remaining effects. Test moving cameras and changing
   weather, not just one still image.
8. Run every source story equivalent at fixed camera, size, time, assets and
   exposure. Record image errors, behavior traces, performance and memory on
   each target. Finish platform packaging and failure/recovery qualification.

## Data and verification limits

The source contains atmosphere LUTs, stars and cloud assets. Their hashes are
in the inventory, but native loading has not been implemented. Story helpers
also reference remote models, environment maps, film LUTs and noise/terrain
data; the recorded imports and source files must be followed when each story
is implemented.

Google photorealistic tiles require an authorized Google Maps key or Cesium Ion
token (asset 2275207 in the source). The hosted demo's working access does not
grant a native app permission to reuse its credentials. No native credentials
were supplied or copied. Provider-specific live tests remain unrun.

No native story image has been compared with upstream yet. Compilation,
headless algorithm tests, native offscreen GPU tests, Flutter presentation,
simulator execution and physical-device execution are separate gates. The
existing core's earlier platform results are documented in its checkpoint;
they are not new evidence for this port.
