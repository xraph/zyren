# Camera behavior reference

You need two control families to reproduce the stories. `GlobeOrbitPlugin`
currently rotates a center-facing Z-up camera; it has no pan, hit pivot, local
ground orbit, damping or orthographic transition. Keep that convenience API
separate from the ported controls.

The snapshot pins `three` 0.184.0 and `3d-tiles-renderer` 0.4.24. Drei 10.7.7
resolves `three-stdlib` 2.36.1, whose OrbitControls differs from Three's addon.
`camera-controls` 3.1.2 appears as a transitive dependency, but no source story
imports its CameraControls. It is not one of the two demonstrated systems.

## Interaction comparison

| Behavior | OrbitControls | EnvironmentControls / GlobeControls |
| --- | --- | --- |
| Primary drag | Orbit around target | Drag the hit surface; globe far mode rotates the ellipsoid under the pointer |
| Secondary drag | Pan | Rotate around raycast pivot; disabled in far globe mode |
| Modified primary | Control/Meta/Shift exchange rotate and pan | Shift-primary rotates; Control/Meta do not select that action |
| Middle drag | Dolly | No dedicated middle-button dolly branch |
| Wheel | Dolly; optional zoom-to-cursor | Zoom toward hovered surface; wheel pixels multiplied by -0.25, lines by 40 and pages by 800 before scaling |
| One touch | Rotate | Surface drag |
| Two touches | Simultaneous dolly/pan by default; configurable dolly/rotate | WAITING state chooses pinch zoom or parallel rotation after movement exceeds 2 times device pixel ratio; selected mode persists |
| More pointers | Orbit's pointer state machine | More than two touch pointers reset the state |
| Keys | Arrow pan after explicit key-listener attachment | Story `useKeyboardControl` adds motion; it is not built into EnvironmentControls |
| Damping | Default false in implementation, factor .05; residual angles/pan multiplied by .95 per update. Drei 10.7.7 enables damping by default and updates before scene frames | Default false, factor .15; decay is `2^(-deltaTime / dampingFactor)` with a quarter-pixel stop threshold and stable-frame checks; stories enable it |
| Distance limits | Default 0..infinity, polar 0..pi, azimuth unbounded; zoom 0..infinity | Environment minDistance 10, max infinity; altitude 0..0.45pi; cameraRadius 5; Globe maxZoom .01 and view-dependent distance/zoom bounds |
| Up direction | Arbitrary camera up transformed into spherical Y-up frame | Local surface normal; globe aligns camera up and north as zoom moves toward space |
| Collision | No terrain-height correction | Raycast height clearance, fallback plane in Environment, ellipsoid in Globe; scene wrapper delays adjustHeight until first interaction |
| Lifecycle | Start/change/end, save/reset, connect/dispose, pointer capture/cancel | Start/change/end, pointer tracker, reset on up/leave/cancel, tile-renderer binding and disposal |

Inspect executable implementations at these pinned sources:

- [Three OrbitControls](https://github.com/mrdoob/three.js/blob/r184/examples/jsm/controls/OrbitControls.js)
- [three-stdlib OrbitControls](https://github.com/pmndrs/three-stdlib/blob/v2.36.1/src/controls/OrbitControls.ts)
- [Drei lifecycle and damping defaults](https://github.com/pmndrs/drei/blob/v10.7.7/src/core/OrbitControls.tsx)
- [EnvironmentControls](https://github.com/NASA-AMMOS/3DTilesRendererJS/blob/v0.4.24/src/three/renderer/controls/EnvironmentControls.js)
- [GlobeControls](https://github.com/NASA-AMMOS/3DTilesRendererJS/blob/v0.4.24/src/three/renderer/controls/GlobeControls.js)
- [Story wrapper and delayed height adjustment](https://github.com/takram-design-engineering/three-geospatial/blob/b012ad06d858fc035d88aacfd73f092f93c994e4/storybook-webgpu/src/components/GlobeControls.tsx)

The npm distributions at those versions were inspected separately. Their code
is development reference material; none belongs in the native application.

## Globe thresholds and clipping

For a perspective camera, let R be the maximum world ellipsoid radius and
v/h its vertical/horizontal fields of view. Near controls apply while distance
to the center is below `max(R/tan(v/2), R/tan(h/2))`. The maximum perspective
distance is twice that threshold. A gesture retains its selected near/far mode
until it ends, so changing altitude mid-drag must not switch algorithms.

For an orthographic camera, transition zoom is the larger view dimension divided
by R; minimum zoom is `.7 * smallerDimension / (2*R)`. Virtual camera positions
drive globe up vectors and clipping. This is a projection-aware transition,
not a fixed altitude cutoff.

Perspective near is at least a blend from 1 to 1000 based on elevation across
`nearMargin * R`, and also at least `distanceToCenter - R - margin`.
`nearMargin` defaults to .25. Far uses the ellipsoid horizon distance plus .1
and `R * farMargin`; elevation has a minimum clamp in the source. Atmosphere
and postprocessing must receive each changed camera range in the same frame.

## Replay gates

Record actual upstream camera position, target/pivot, orientation, clipping,
zoom, emitted events and frame demand after each input. Replay the same stream
against Dart at 30, 60 and 120 updates per second, including stationary release
frames, modifier switches, wheel units, pointer cancellation and resize.

Test both Y-up and Z-up local scenes. Globe tests need perspective and
orthographic cameras, near/far boundary crossings, sky misses, horizon drags,
ground clearance, translated/rotated ellipsoid groups and low-LOD replacement.
Touch tests must distinguish two-finger pan/orbit from pinch selection; a generic
Flutter scale callback alone loses the pointer information this requires.

No control replay gate has passed yet. Exact input traces and native screen
comparison remain required even after the camera maths is ported.
