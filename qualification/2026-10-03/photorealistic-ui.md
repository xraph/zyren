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
