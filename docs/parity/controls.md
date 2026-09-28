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

The three-stdlib and r184 replay gates pass for the cases listed in
[the stdlib evidence](native-orbit.md) and [the r184 evidence](three-orbit.md).
EnvironmentControls now passes 24 upstream replay cases across perspective and
orthographic cameras, Y/Z up, damping and 30/60/120 Hz. The traces cover surface
dragging, pivot rotation, wheel units, resize, touch arbitration and idle frames.
Additional tests cover terrain clearance, interrupted input and plugin disposal.
Native wheel events refresh their target even without a preceding pointer move;
this intentionally avoids a stale pointer jump in upstream orthographic zoom.
Globe inward zoom also refreshes its ray when returning from far navigation,
where camera tilting can leave the old ray pointing away from Earth. This avoids
crossing the surface after a large scroll reversal from orbit. The pinned
trajectory tests still pass.
CameraTransitionManager passes 12 upstream traces and a fixed-point projection
check. GlobeControls passes 24 traces at 30/60/120 Hz with both camera types,
near/far modes, damping, horizon misses and translated/rotated Earth frames.
Position and clipping error is below 0.1 mm in these recorded cases.

The port keeps an orthonormal camera frame at the top-down tilt limit. Upstream
can create a non-unit quaternion there, so that boundary has a separate invariant
test rather than a claim of trajectory parity. Uniform world scale also scales
horizon distances; nonuniform and sheared frames are rejected. These corrections
are deliberate. Orthographic `zoomSpeed` scales the exponent of the zoom factor,
so positive sensitivity preserves the requested direction and stationary pinches
keep zoom unchanged. Upstream multiplies the final factor by sensitivity, which
reverses some inputs at speeds below or above one. Wheel and pinch regressions
cover speeds 0.5, 1 and 2 in environment and near/far globe controls; all default
speed replay traces still pass. [Native navigation evidence](native-navigation.md) records the
macOS integration and the pending mobile checks.
Full story screenshot comparison remains unrun.

## Native input contract

The host now exposes optional `ViewportInputSource` and `KeyboardInputSource`
capabilities over the existing input stream. Viewport dimensions use logical
units, independently of device pixel ratio and render resolution. Keys require
an explicit registration and scene focus. Clicking a text field transfers key
ownership away from the scene; held keys receive cancellation on focus loss,
unregistration, suspension and detachment.

Controls can register `SceneGesture.pointerDrag` to claim raw pointer gestures.
Flutter then gives those drags to the scene instead of an ancestor scroll view.
Pointer IDs and individual positions remain available for upstream touch state
machines. Suspension and detachment cancel active pointers. Wheel ownership
still requires a separate scroll registration.

That scroll registration also claims native trackpad pan/zoom gestures. You can
use two-finger scrolling or pinching to zoom. Pan deltas use local logical pixels
with the wheel direction; incremental pinch ratios become `-200 * log(ratio)`
wheel pixels. The cursor stays at the gesture's starting location. This path
does not also emit touch-scale updates. Suspension, detachment and removal of
the last scroll registration cancel pending trackpad motion.

Widget tests cover transformed viewports at DPR 1.5 with two render scales,
text-field focus, key repeat/cancellation, claimed drags, detachment and both
claimed/unclaimed wheel input. These are host input checks, not control parity.
Trackpad tests also cover parent scroll ownership, cumulative pinch ratios,
transformed viewports at DPR 2, interrupted gestures and ordinary touch pinch
while trackpad zoom is registered.
