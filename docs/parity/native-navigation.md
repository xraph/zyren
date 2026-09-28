# Native surface navigation

You can run the Planet navigation example with:

```sh
cd examples/planet
flutter run -t lib/navigation_lab.dart -d macos
```

The viewport supports surface dragging, pinch zoom, secondary-button rotation,
location picking and animated perspective/orthographic transitions. The globe
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
76 presented frames, 16 stats samples, zero ordinary readback bytes and zero
sessions, renderers, held drawables or retiring resources after disposal.
The app could not be foregrounded, so this is native integration evidence rather
than a manual inspection of its window.

Pixel Vulkan and iPhone Metal runs are pending device access. The Pixel has its
lock screen showing; the iPhone app launched but the wireless test connection
has not completed. This checkpoint adds no Windows or Linux qualification.

These results cover navigation. Renderer integration and atmosphere still have
their own implementation and qualification gates in the execution plan.
