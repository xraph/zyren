# Example screenshots

Captured on 2 October 2026. These are native app screenshots, with the example
controls and rendered scene kept together. The Android captures use a physical
Pixel 9 Pro in landscape. The macOS captures use an Apple M3 Max.

| Image | Example target | Backend | View |
| --- | --- | --- | --- |
| [Materials](materials-macos.jpg) | `examples/shader_lab/lib/physical.dart` | Metal | Thin film, sheen and glass |
| [Workbench](workbench-android.png) | `examples/multiple_views/lib/scene_workbench.dart` | Vulkan | Selected housing with transform handles |
| [Atmosphere](atmosphere-macos.jpg) | `examples/planet/lib/atmosphere_lab.dart` | Metal | Orbit, Dusk, Haze enabled; zoomed out |
| [Globe](globe-android.png) | `examples/planet/lib/navigation_lab.dart` | Vulkan | Initial perspective view with geographic markers |

Run a target from its example directory with
`fvm flutter run -d macos -t lib/<target>.dart`, replacing `macos` with your device
ID for Android. Capture the app window on macOS or use `adb exec-out screencap -p`
on Android. Wait for the scene to render and for transient notifications to clear.

For this capture, the geospatial targets ran through the `multiple_views` native
host using `-t ../planet/lib/<target>.dart`. The macOS atmosphere capture used a
temporary app bundle with a distinct identifier so the running Planet session
could stay open. Its window title therefore reads `multiple_views`.

Keep screenshot assets here, outside the ignored local `docs/` directory. Link
to these files from the root README so GitHub can display them on any branch.
