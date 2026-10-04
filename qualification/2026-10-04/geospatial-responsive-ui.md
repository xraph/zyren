# Responsive geospatial scenes, 4 October 2026

All 15 entries in `examples/planet` now use the same responsive controls and info
layout as the photorealistic Earth/cloud scene. You can return to the launcher
from one toolbar. Opening a panel keeps the canvas mounted and at the same size.

Panels start closed below 1000 logical pixels. From 600 pixels wide, they sit at
the side; narrower screens use a bounded bottom panel. Both panels scroll. Touch
targets stay at their normal size, and Escape returns focus to the toolbar toggle.
The launcher header and filters scroll with the scene list on short windows.

## Checks

- 29 Flutter tests pass: 9 launcher, 8 ocean, 7 world-tool, 2 shared-panel and
  3 photorealistic control tests. They cover 320-pixel widths, landscape, desktop
  and text at 100%/200%. Shared-panel tests also check focus, scene input and
  stable mount/disposal counts across resizing.
- Ocean layouts were rendered and inspected at 1440x900, 390x844 and 844x390.
  These captures use a labelled canvas placeholder and establish UI layout only.
- macOS Metal ocean integration passes all six scenes, pause, independent layers,
  stable canvas/controller identity across panel changes, zero presentation
  readback and cleanup after returning to the launcher.
- macOS Metal atmosphere integration passes day, dusk, night, orbital view,
  narrow resizing and cleanup. Presentation readback remains zero.
- macOS Metal camera integration passes saved poses, roll, projection changes,
  narrow resizing and cleanup. It presents six frames with zero readback.

The Pixel 9 Pro Android 17 native integration also passes all six ocean scenes,
panel controls and return/cleanup. The [revision-2 receipt](ocean-scenes-2/pixel-native.json) records zero pixel
readback and at least six simulation ticks for every scene at 960x1989.
Android reported a locked screen during setup. The delay was not isolated,
and the test duration is not rendering-performance evidence.

The initial layout sweep exposed long switch labels and ocean selectors that
could overflow at 200% text. Switch rows now wrap, selector labels sit above their
values, and menu items can wrap. Renderer failures and unavailable offline data
retain their shared ZeroState actions. Offline probes and diagnostics live in
Scene info so the toolbar cannot cover them.

These UI checks do not qualify live provider access, water performance, final
water art or unrun devices. See [ocean qualification](ocean-lab.md) for those gates.
