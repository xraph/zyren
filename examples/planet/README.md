# Geospatial scenes

Run `fvm flutter run -d macos` from this directory to open the scene launcher.
Photorealistic Earth, clouds, six ocean scenes, layers, offline regions, terrain,
3D Tiles and camera fixtures share this app. Pick a scene, then use **All scenes**
to return. Native renderers start only when you open a scene.

The Earth scenes use the existing provider configuration below. Ocean and local
fixtures need no provider credentials. See the [ocean notes](OCEAN.md) for controls,
captures and open qualification gates, or the [workspace README](../../README.md)
for setup. Direct lab targets remain available for existing test commands.

# Camera pose lab

Run `flutter run -d macos -t lib/camera_lab.dart` to use the ported PointOfView
with the shared native Metal SceneView. The [camera lab notes](https://xraph.com/docs/zyren/reference/parity/native-camera-lab)
cover device commands, runtime checks and remaining limits. This is a numerical
port fixture with local calibration geometry; city streaming, atmosphere and
clouds remain in the [full parity matrix](https://xraph.com/docs/zyren/reference/parity/matrix).

# Terrain streaming lab

Run `flutter run -d macos -t lib/terrain_lab.dart` to explore a deterministic
terrain patch with checker imagery. The camera presets change detail as you
move. Scroll or pinch to zoom, or drag to orbit.

At a detail camera, enable **Offline test** to fail child loads while the parent
stays visible. **Reconnect and retry** restores finer terrain. The footer shows
loading requests, cached CPU bytes and visible GPU payload bytes.

The [terrain notes](https://xraph.com/docs/zyren/reference/parity/terrain-streaming) cover source contracts,
native verification and limits. This fixture needs no provider credentials.

# Google Maps lab

Run the Google Maps lab with your own Maps Tile API key or a Cesium Ion token
that can access Google's asset 2275207. Put one of these fields in a private JSON
file outside the repository: `ZYREN_GOOGLE_MAPS_KEY` or `ZYREN_CESIUM_ION_TOKEN`.
The lab uses the Google key when both are supplied.

```sh
flutter run -d macos -t lib/google_tiles_lab.dart --dart-define-from-file=/path/to/private-provider.json
```

Use your connected device ID instead of `macos` for Android or iOS. The lab
requires native presentation. It opens Manhattan, provides a Fuji preset and
uses the shared globe controls for surface navigation and orbital zoom.

Credits follow the visible tiles. You can open Data sources for the full text
on a narrow screen. Provider content stays in memory, and the scene releases
its requests and resources when you close it. Device profiles reserve native
resources for tile refinement and replacement uploads.

The live integration test uses the same private configuration:

```sh
flutter drive -d macos --driver=test_driver/integration_test.dart --target=integration_test/google_tiles_test.dart --dart-define-from-file=/path/to/private-provider.json
```

It checks native presentation, Manhattan and Fuji geometry, a stable camera, attribution
at desktop and narrow widths, and cleanup. It needs provider access and a network
connection. For a local synthetic dataset, run `lib/tiles3d_lab.dart` or its
`integration_test/tiles3d_streaming_test.dart` test instead.

# Source story qualification

Add `--dart-define=ZYREN_LAB_CLOUDS=true` to open Tokyo, Fuji and London with
the pinned cloud maps and blue noise. Use the Clouds selector to choose Auto,
Low, Medium, High or Ultra. Auto starts phones at Low and tablets/desktops at
High. You can select a higher quality while the scene is running. The phone
default reduces cloud sampling and resolution; the city render size stays the
same. It does not resolve tile upload failures during navigation.

Auto adapts cloud sampling and stable shadow update cadence to measured scene GPU
pressure. Named quality presets keep fixed sampling. Auto retains its maximum
cloud allocation while changing the active grid, so lower sampling does not mean
lower texture residency. The navigation benchmark records requested and applied
adaptation separately. See the [October rendering qualification](../../qualification/2026-10-03/rendering-performance/README.md)
for native checks and the incomplete foreground route.

Switch **Cloud shadows** off to skip the shadow maps and light shafts while
keeping the clouds visible. The **Shadows** selector sets Low, Medium, High or
Ultra independently of cloud quality. Auto follows the Clouds selector. Turning
shadows off keeps your chosen shadow quality for the next time you enable them.

Move **Sparsity** toward 100% for fewer clouds. At 0% you keep the location's
preset coverage; 100% clears the cloud layers and their shadows. This leaves
the density settings and atmospheric haze unchanged.

Move **Density** from 100% toward 0% to thin all cloud layers. Coverage and the
relative density of each layer stay the same. Switch **Animate clouds** off to
freeze their current position. The image still finishes refining, then stops
requesting continuous frames. Turn it on to resume with the same velocities.
These controls keep your choices when you change a location or quality preset.

Phones allow 128 MiB of tile payloads, tablets 192 MiB and desktops 384 MiB.
The native resource limits are 384, 512 and 768 MiB respectively. Phones load six
tiles concurrently; tablets and desktops load eight. The screen-error target is
eight render pixels. The selected tile limits are 512, 768 and 1024, with decoded
cache limits of 512, 768 and 1024 MiB respectively. A tile budget warning means
selection count, decoded data or visible payloads exceed the profile's allowance.

Scene uploads target 2 MiB per frame on phones and 4 MiB on tablets and desktops.
During a larger replacement, the renderer keeps the previous complete scene
following your camera while it uploads the new resources over several frames.
This spreads upload work without reducing the tile residency allowance. A single
asset above the target uploads alone; the hard protocol limits still apply.

| Device | Scene edge / total pixels | Auto cloud edge | Ultra cloud edge |
| --- | --- | --- | --- |
| Phone | 1600 / 1,572,864 | 512 | 1920 |
| Tablet | 1920 / 2,097,152 | 1536 | 2560 |
| Desktop | 1920 / 2,097,152 | 1920 | 4096 |

Auto cloud targets cap total pixels at 589,824 on phones, 1,572,864 on tablets
and 2,097,152 on desktops. Ultra raises those ceilings to 2,097,152, 4,194,304
and 8,388,608 pixels. A cloud target never exceeds the scene viewport, so the
scene's own limits still apply. Larger cloud targets cost more GPU time.
The phone's Low Auto preset also limits each edge to 512 pixels.

Android and iOS views with a shortest display side of at least 600 logical pixels
use the tablet profile. Orientation does not change the classification. Desktop
windows keep the desktop profile at narrow widths.

Larger displays use a bounded render target; waiting longer does not lift that
limit. The rounded area cap leaves room for old and replacement effect textures
during a resize. Cloud quality changes restart refinement, and a failed change
keeps the current setting available with a retry action.

You can run one city and save its inputs and checks from the workspace root:

```sh
python3 tool/qualification/geospatial_stories.py run --preset london --device macos --provider-config /path/to/private-provider.json --output /tmp/zyren-london-metal
python3 tool/qualification/geospatial_stories.py report --output /tmp/zyren-story-report.json /tmp/zyren-london-metal/evidence.json
```

Use a fresh output directory for each run. Pass `--flutter` when Flutter is not
on your PATH, and `--ios` with an iPhone device ID. The runner keeps phone apps
installed so you don't have to repeat developer trust after every test. After a
device test, launch a normal app build before checking touch or gestures. Flutter's
integration-test binding can discard physical input in the retained test app.
See the [qualification runner guide](../../tool/qualification/README.md) for
normal-app restoration and launch commands.

The report retains all 74 pinned source stories. Five city scenes are registered
so far. A passing native run records the camera, date, viewport, backend, central
pick, attribution and cleanup. It does not certify image parity. Full source
image comparisons are still pending, and unregistered scenes stay visible in
the report. Each run includes file hashes before and after execution; changed
source or incomplete checks cannot produce a qualified result.

The fixture also hashes each atmosphere table and cloud map it loads. Those
bytes must match the upstream Git LFS hashes in
`assets/qualification/source_assets.json`: four atmosphere tables and, for cloud
scenes, five weather, shape and noise maps. Provider tile content stays outside
this asset manifest. You still need live provider access for the city geometry.

For the offline cloud, lens and SMAA regression, run:

```sh
flutter drive -d macos --driver=test_driver/integration_test.dart --target=integration_test/cloud_effects_test.dart
```

That fixture needs no provider credentials. It checks native presentation,
temporal history, resizing and resource disposal.

### Night-side tiles

The Google cloud and atmosphere labs default to **Moonlight: Visible**, which
adds phase-aware lunar lighting and a small night fill so tile detail remains
visible when the Moon is down. Choose **Natural** for the lunar irradiance scale
without fill, or **Off** to keep the existing sun and sky relighting. **Night
view** sets the selected location to 23:00 local solar time; turn it off to return
to the preset's original time. These choices survive location and cloud quality
changes. Lunar lighting also reaches cloud volumes. Night view increases the
star catalogue brightness and uses a 2048-pixel star target, so bright stars can
remain visible between clouds. Daytime returns to the original star intensity.

The selectors stay on the page and wrap on narrow screens. The Mac runner guards
Flutter 3.47.5's accessibility bridge against partial updates arriving before
its root after a focus change. This compatibility hook uses internal Flutter
selectors and needs live accessibility checks when you upgrade the SDK.
The root parser passes tests against the current engine ABI; focus and control
qualification for this guard remains pending while the Mac is locked.
Planet makes one automatic recovery attempt when the native renderer explicitly
requires recreation after a GPU failure. A repeated failure stays visible with
the renderer retry action.
Qualification builds can enable
`ZYREN_RENDER_TELEMETRY=true` and inspect `ext.planet.renderStatus` with
`tool/qualification/read_render_telemetry.dart`. This measures accepted native
presentations; the slower diagnostics stream is unsuitable for frame-rate checks.
