# Native surface navigation

You can run the Planet navigation example with:

```sh
cd examples/planet
flutter run -t lib/navigation_lab.dart -d macos
```

The viewport supports surface dragging, two-finger trackpad scrolling, pinch
zoom, secondary-button rotation, location picking and animated
perspective/orthographic transitions. The globe
plugin uses the shared ellipsoid service and public core camera/input APIs.

## Reference evidence

- Camera transitions: 12 traces at 30/60/120 Hz, positional zoom on/off, rotated
  camera frames, reversal, fixed-point projection and lifecycle events.
- Environment controls: 24 traces across both camera types and Y/Z-up scenes,
  including damping, wheel units, modifiers, touch arbitration and resize.
- Globe controls: 24 traces across both camera types, near/far navigation and
  translated/rotated Earth frames. The traces include horizon misses, pinch and
  two-finger rotation. Position and clipping error stays below 0.1 mm.
- Additional checks cover terrain queries, uniform world scale, invalid frames,
  tilt-limit stability, interrupted input, camera replacement and disposal.

The source is 3d-tiles-renderer 0.4.24 with Three 0.184.0. Reproduction scripts
are `tool/{transition,environment,globe}_reference.mjs`. Each takes a reference
dependency directory and an output file; no JavaScript runs in the application.
The deliberate upstream differences are recorded in [controls.md](controls.md).

## Native evidence

The macOS Metal integration passed selection, surface dragging, both animated
projection transitions, a 390 by 700 layout, suspend/resume and reset. It reported
73 presented frames, 17 stats samples, zero ordinary readback bytes and zero
sessions, renderers, held drawables or retiring resources after disposal.
The app could not be foregrounded, so this is native integration evidence rather
than a manual inspection of its window.

The Pixel 9 Pro Vulkan run passes the same navigation test: 64 presentations,
18 samples, zero readback bytes and zero remaining native owners. The iPhone 16
Pro Metal profile run also passes, with 75 presentations, 18 samples, zero
readback bytes and clean teardown. The iPhone driver keeps Planet installed to
preserve device trust. This checkpoint adds no Windows or Linux qualification.

The macOS run was repeated after renderer, atmosphere and orthographic sensitivity
changes. See the [combined qualification](navigation-renderer-atmosphere-checkpoint.md)
for the implemented renderer/atmosphere profiles and separate device results.

## Trackpad zoom

You can scroll with two fingers or pinch over the viewport to zoom in and out.
Faster gestures zoom farther and keep moving briefly after your fingers lift,
then slow to a stop. A new gesture or a click on a control interrupts the motion.
Keep zooming out to leave the surface and see Earth from orbit. The shared
Flutter adapter claims native pan/zoom events when the controls register scroll
input, preserving the existing touch gestures and the parent page's scrolling
outside the scene. [Input normalization](controls.md#native-input-contract)
describes the cursor anchor and cancellation behavior.

`integration_test/trackpad_zoom_test.dart` passes on macOS Metal. It injects
Flutter native trackpad events into the atmosphere demo, starts 1,500 metres
above Earth in both ground-facing and horizon-facing views, and reaches
20,977,781 metres altitude through repeated two-finger scrolling. Pinching zooms
in and out near the ground and returns toward Earth from orbit. Camera positions
remain finite, clipping stays valid and the far view faces the planet. Reversing
scroll direction from orbit also keeps the camera above the surface.

Inward zoom now refreshes the cursor ray after far navigation has turned the
camera toward Earth. Previously, a cached ray could still point toward the old
horizon, miss the planet and let a large inward delta cross the surface. Three
regressions cover that reversal at 400, 800 and 1,600 wheel-equivalent pixels.
Large outward bursts also respect the orbital distance limit when they cross
the near/far boundary in a single frame. At that limit the camera faces Earth.

The native test also sends a timed flick and verifies that the camera continues
moving toward Earth after release, then interrupts the tail with a new gesture.
The run checks a 390 by 700 layout. It reports 552 presentations, 141 stats
samples, zero ordinary readback bytes and no remaining sessions, renderers,
held drawables or retiring resources. All 89 Flutter tests, 89 geospatial tests
and 184 OrbitControls/plugin checks pass, as do analysis and package-boundary
checks. These are injected
gesture tests; physical trackpad pinch feel has not been manually qualified.
