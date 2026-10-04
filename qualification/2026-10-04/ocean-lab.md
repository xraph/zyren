# Ocean scenes, 4 October 2026

The ocean demos now live in the existing `examples/planet` photorealistic app.
Its default `main.dart` opens a compact launcher with Earth, Ocean and World tools
filters. The launcher creates a scene when you open it and returns to the list
when you close it. The separate ocean app was removed before publication, as
requested on 4 October.

## Implemented and checked

- Six saved scenes pin their epoch, camera, wave seed and source revision. They
  exercise native water, atmosphere, foam, underwater transport, caustics and a
  native buoyant hull. The orbit scene supplies a 30-second camera route.
- The coast height, depth and mask use a persisted D3 manifest. A cold restart
  reads checksum-verified resources with transport disabled. The source is owned
  synthetic data, not a geographic survey.
- Custom detail profiles use 16/32/64/128 visual grids. The physical source stays
  at 128 and the simulation owner stays at 60 Hz. These are not stock presets.
- Three Dart tests pass, including all six scenes on native Metal and zero live
  registry allocations/graphs after each scene closes.
- Responsive controls now share the existing photorealistic layout across all
  15 launcher entries. Desktop side panels and phone bottom panels preserve
  canvas size. Controls and info can be scrolled and dismissed.
- Twenty-nine Flutter tests pass across the launcher, ocean, seven world tools
  and photorealistic controls. Coverage includes 320-pixel widths, phone landscape,
  desktop and text at 100%/200%. The launcher header scrolls with its scene list.
- The macOS native-view integration passes through the shared launcher: all six
  scenes, pause, independent layer controls and disposal on return. The native
  surface reports zero pixel readback.
- Twenty-two Flutter backend tests pass after adding the missing
  `scaledOpaqueCapture` declaration to the Metal and Android surface adapters.
  That adapter test uses a mocked channel; it does not qualify an Android device.

The [responsive UI record](geospatial-responsive-ui.md) separates rendered layout
checks from native scene runs.

The earlier [host record](ocean-integration.md) contains the actual 100-resize
resource cycle and lifecycle tests. Analysis and package-boundary checks pass.

## Desktop capture and timing

The [capture report](ocean-lab-captures/report.json) records 60 fixed timestamps
per scene at 1280x720 on this Apple M3 Max macOS host. The custom balanced profile
uses a 32 grid and a 192-patch cap. Five warmup frames are excluded. This is an
exploratory readback run on a shared development machine, not a sustained display
benchmark or the specified desktop High/1080p target.

| Scene | Host p50 ms | Host p95 ms | Host p99 ms | Render submission GPU p95 ms |
| --- | ---: | ---: | ---: | ---: |
| Open water | 33.035 | 42.195 | 49.528 | 21.192 |
| Storm swell | 38.329 | 52.400 | 64.640 | 22.200 |
| Shallow coast | 61.645 | 120.217 | 149.049 | 16.186 |
| Buoyant vessel | 53.520 | 101.417 | 114.239 | 16.502 |
| Underwater | 47.445 | 101.560 | 123.582 | 12.942 |
| Orbit route | 51.506 | 261.638 | 1424.275 | 26.771 |

Host elapsed time includes plugin preparation, queries, GPU completion and pixel
readback. The GPU column covers the main render submission and excludes separate
wave/interaction compute submissions. Total-frame GPU time, isolated water cost
and physical GPU residency remain null. No frame-rate target passes from this run.

In the original revision-1 capture run, the three sampled points in calm, coast, vessel and
underwater scenes pass the current query policy. Storm and orbit samples report
`OceanQueryFailure.accuracy`. Their failures remain visible in JSON; no substitute
height or weaker policy was used. Error bounds describe the numerical model,
not agreement with real seawater. [Revision 2](ocean-query-admission.md) now admits
the checked samples by reducing horizontal choppiness while preserving the
vertical spectrum. The original capture report remains unchanged.

Every scene returns to zero owned registry allocations and graphs after disposal.
Still images and normal/foam debug views are beside the report. The
[vessel motion](ocean-lab-captures/vessel-motion.mp4) covers 240 fixed 60 Hz frames;
its [report](ocean-lab-captures/motion-report.json) records the same physical path.
Source PNG frames were retained only in the temporary capture directory.

## Remaining gates

| Gate | Status |
| --- | --- |
| Real Earth coast/bathymetry | Blocked on an identified dataset, documented provenance and offline distribution terms |
| Desktop High, 1920x1080 at 60 fps | Unqualified; only exploratory custom-profile timings exist |
| Mobile Medium, 1280x720 at 30 fps | Unrun |
| Storm/orbit query admission | Revision 2 passes the recorded default-policy samples; see [admission record](ocean-query-admission.md) |
| macOS native-view scene launcher | Six scenes, controls and cleanup pass |
| Android Vulkan | Pixel 9 Pro six-scene native integration passes; performance remains unqualified |
| iPhone Metal | Device run pending |
| iPad Metal | Device run pending |
| Windows DX12 | Unrun |
| Linux Vulkan | Unrun |
| Professional visual acceptance | Open; horizon artifacts, scene detail and final effects need further work and user review |

The vessel and coast are functional procedural fixtures. Their geometry and
materials do not establish the requested final art quality. Navigation with live
traffic, flight and orbital simulation solvers remain later platform work.
