# Native night rendering

The changes are committed locally. Final device and accessibility qualification
is incomplete. The Mac is locked, iPad launch is denied because it is locked,
and iPhone Mirroring needs a human unlock. Keep the Apple connection wireless.

## Rendering changes

Night view raises the star catalogue intensity from 1,000 to 50,000 and uses a
2048-pixel star target. An earlier native capture shows visible stars with cloud
density at zero. Fresh night images on the final builds remain pending.

Moonlight now reaches cloud volumes as well as globe tiles. Natural retains the
phase-aware lunar scale. Visible increases lunar brightness and adds a small
night fill, so detail remains visible when the Moon is below the horizon. Off
removes both lunar light and night fill. Density and animation settings survive
location and quality changes.

The source cloud volumes now use filterable RGBA8 textures with mipmaps and
independent W wrapping. The source R8 voxel values are preserved. Imported
atmosphere LUTs use hardware filtering, while generated RGBA32 LUTs retain their
explicit interpolation. Corrected weather-map footprint sampling removes the
bright grid in the isolated orbital fixture. A final app orbital capture is
still required.

High clouds can fill an HD desktop scene target. Ultra has edge ceilings of
1920, 2560 and 4096 pixels on phone, tablet and desktop respectively, with area
ceilings of 2, 4 and 8 Mi pixels. Planet still bounds its scene targets separately.
The exact limits are in [Planet's README](../../examples/planet/README.md).

Visible tile payload budgets are 128, 192 and 384 MiB. Decoded caches are 512,
768 and 1024 MiB, with selected tile limits of 512, 768 and 1024. Larger budgets
allow more geometry but do not remove the budget warning. The expanded Tokyo
capture showed 418 tiles and two `decodeFailed` tiles. The final locked-host
snapshot has 389 visible tiles and one `decodeFailed` tile. These failures
remain open.

The streamer now uses a priority heap, caches screen errors, stops admission
when no request can fit, and reuses a stationary selection. Camera revisions,
viewport changes, loaded content and eviction invalidate that selection. HTTP
freshness and refinement fades remain active.

Tile refinement now follows the actual rendered pixel height instead of the
logical touch surface height. Culling retains the logical viewport aspect. The
regression tests reproduce coarse detail at a doubled render target before the
fix, and check both refinement and a reduced resolution cap after it. This applies
to perspective and orthographic views. Live mobile detail remains unverified.

## Controls and Mac stability

Rendering choices stay on the page and wrap on narrow screens. The shared
ZeroState scrolls if the viewport is too short for its explanation and action.
Widget checks cover both 1000-pixel and 390-pixel widths.

The crash recurred with persistent selectors. Both recent macOS crash reports
point to `AccessibilityBridge::CreateRemoveReparentedNodesUpdate`, followed by
`CommitUpdates` and `updateSemantics`. The pinned Flutter source dereferences a
child's missing parent when a partial update has become the root of a new tree.

Planet's Mac runner now waits for a root update after the native semantics bridge
resets. This is a compatibility hook using internal Flutter selectors. Its C
parser is checked against Flutter 3.47.5's actual embedder structs with address
and undefined-behavior sanitizers. The SDK itself is unchanged. Live focus,
accessibility-tree and control checks remain pending, so the crash is not yet
qualified as resolved. Requalify the hook when you upgrade Flutter.

## Timing and reference comparison

[Recorded observations](night-rendering.json) use accepted native presentations,
not the diagnostics stream, which is throttled to 200 ms. The earlier roughly
5 FPS claim from that stream is invalid.

At a 1600 by 768 viewport, earlier foreground observations ranged from 26.6 FPS
with 194 tiles to 18.3 FPS with 418 tiles. These used different budgets. They
are not a controlled before-and-after benchmark, and they do not cover the
final full-resolution High cloud target, stationary-selection and render-pixel
refinement changes.
GPU timing was unavailable and remains null.

The final locked-Mac attempt accepted hundreds of frames with a 1600 by 768
cloud target, then failed when native GPU completion exceeded its two-second
wait. The renderer requested recreation. That window is excluded from FPS
comparisons. We have not established whether the lock caused the timeout.
An unlocked rerun is required.

The native Apple adapter now reports the renderer's explicit recreation request
as `deviceLost`, and both Metal and Android Dart adapters preserve that code.
Planet opts into one automatic recovery attempt. Repeated failure still exposes
the retry action. Native failure classification, adapter propagation and the
bounded recovery policy passed their tests; live recovery after this GPU timeout
remains unverified. The telemetry tool now excludes failed-state FPS windows.

The restored final Mac build reports SceneReady, a 1600 by 768 cloud target,
389 visible tiles and no active loading. Automatic recovery had not been used
in that snapshot. The Mac was still locked, so this confirms accepted native
frames rather than visual appearance or foreground performance.

The public [Takram Tokyo story](https://takram-design-engineering.github.io/three-geospatial/?path=/story/clouds-3d-tiles-renderer-integration--tokyo)
was captured with a verified 1600 by 768 canvas, High clouds, coverage 0.35,
7.5-hour local solar time, day 170, exposure 10 and AgX. Its HUD showed 122 FPS.
Its clouds were paused, its shadow map was 512 pixels, and its target and loaded
content differed from the native observation. This provides a visual reference.
It does not establish performance parity.

## Checks and remaining qualification

Thirty streaming/selection/fade tests, four cloud-device tests and eight
Planet widget/profile tests passed. Another 23 backend, controller and recovery
tests passed, for 65 Dart/Flutter tests in this pass. Both native C/Objective-C
qualification executables passed with sanitizers. Dart analysis passed. macOS,
iOS and Android
ARM64 profile builds passed at commit `5495091`, and the final mobile apps
installed on iPhone, iPad and Pixel 9 Pro.

The iPhone launches wirelessly. The iPad launch remains denied as Locked.
Mirrored Pixel slider input worked, but mirrored button taps did not commit a
change. A direct phone tap is needed to distinguish input transport from app
behavior. Touch controls and moonlight images are not yet device-qualified.

The remaining checks are unlocked Mac accessibility and moonlight/star/orbital
images, iPhone and iPad touch/images, Pixel buttons, and a matched foreground
performance comparison. Tile decode failures also need diagnosis; the read-only
VM snapshot had no retained asset exception with which to inspect their cause.
No push or merge was performed.
