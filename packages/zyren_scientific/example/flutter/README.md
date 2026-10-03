# Scientific lab

Run `flutter run -d macos` or select a connected native device. Use the workspace
SDK from `.fvmrc`. The lab requires native presentation and shows its presentation
path and readback byte count above the canvas.

You can switch between slices, isosurfaces, vector arrows, streamlines, temporal
slices and a GPU volume. The inputs are synthetic: a Gaussian temperature pulse
and steady rotational vectors. Temperature is in kelvin, coordinates in metres,
and vector components in metres per second. Drag the scene to orbit. Click a
surface to inspect its source value and, for isosurfaces, its source cell.

Temporal controls interpolate the scalar source. The vector field stays static.
Volume opacity is defined per 0.1 m and clips against opaque scene depth. An error
or unsupported native presentation path appears in the shared ZeroState.
