# Photorealistic example panels

You can open Controls or Info from the toolbar and close either panel with its
close button, its toolbar toggle or Escape. Opening Info replaces Controls.
Your camera, lighting and cloud settings stay in place.

Controls open on the left by default at widths of 1000 logical pixels or more.
At tablet widths from 600 pixels, the same left panel starts closed. Narrower
views use a bottom panel that starts closed. Panels fit their contents and
scroll when needed, leaving the scene available outside their bounds.

Info contains visible and loading tile counts, tile failures and retry actions,
the tile-budget notice, rendering quality and full source credits with working
links. Google Maps and non-collapsible provider credits remain in a compact
footer. Long credits can scroll without consuming the whole height of a short
window. The photorealistic lab no longer opens a source-attribution dialog.

The scene keeps the same widget state and bounds when panels change. Controls
use persistent choices with touch targets, so this layout does not introduce
popup routes or resize GPU targets when you open a panel.

## Checks

Ten widget tests passed across the layout, cloud controls, moonlight controls,
provider-access states and attribution. The layout matrix covers 320x320,
320x568, 390x844, 600x960, 834x1194, 844x390, 1024x768 and 1440x900 at both normal
and doubled text size. Checks include scrolling to the last control, input
outside the panel, unchanged scene bounds and mount count, resize behavior,
Escape focus restoration, settings surviving panel switches and inline links.

Rendered widget captures were inspected at phone, tablet and desktop sizes.
These captures used the missing-provider state and do not show live tiles.
Analysis passed for the changed Dart files. The final macOS profile build
passed. A native Mac launch of the initial layout pass showed the compact
controls/info toolbar and credit strip over live Google tiles.

The final panel-sizing adjustment was checked in the rendered widget captures.
Physical phone/tablet touch checks were not repeated, and their installed apps
were preserved. No rendering-performance or GPU-stability claim comes from
these UI checks.

## Mobile installation

You can now open the updated photorealistic example as Planet on the iPhone,
iPad and Pixel. The responsive UI from `b7215698` was built with Flutter 3.47.5
in profile mode, using `lib/google_tiles_lab.dart`, clouds enabled and the
existing local Google Tiles configuration. Builds used the shared main worktree,
which also contained concurrent changes, so these are not clean-commit artifacts.

The signed iOS build and ARM64 Android build passed. The iOS signature passed
`codesign --verify --deep --strict`. Updates used `devicectl device install app`
and `adb install -r`, without uninstalling the existing apps.

| Device | Install | Launch | Process check |
| --- | --- | --- | --- |
| iPhone 16 Pro | Passed | Passed | PID 13843 remained alive after 136 seconds |
| iPad Pro 13 M4 | Passed | Passed | PID 5080 remained alive after 133 seconds |
| Pixel 9 Pro | Passed | Cold launch passed | PID 26752 remained alive after 36 seconds |

The apps remain installed. These checks establish installation and process
survival. Physical touch, rendered mobile layouts, live tile loading and GPU
stability were not qualified again during this installation.

Frozen packages and install/launch records are under
`/tmp/planet-responsive-mobile-20261003/`. Build logs are
`/tmp/planet-responsive-ios-install-build.log` and
`/tmp/planet-responsive-android-install-build.log`.

SHA-256 of the iOS `Frameworks/App.framework/App` executable:
`146600d514396f082c45e5225a8ec6e9ae16224976679cfffca3055c3d9486d2`.
SHA-256 of the Android APK:
`fe25e440159cb5428ab94a180a1c8df92db7742f284216a1c27a9008b413f1c8`.
