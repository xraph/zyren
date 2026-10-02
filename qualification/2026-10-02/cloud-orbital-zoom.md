# Cloud orbital zoom

Zooming from Tokyo into space could stop the native renderer with
`Cloud shadow far distance must exceed camera near`. This was reproduced in the
normal macOS Google cloud lab through trackpad scrolling. The process stayed
alive and showed the renderer error view.

Globe navigation moves the near clipping plane outward to preserve depth
precision. The cloud frame capped its shadow range at 200 km, then multiplied
the camera's far distance by the configured shadow scale. At orbital distances,
this first reduced the shadow interval to one metre and eventually put the
shadow far plane behind the camera near plane.

Commit `9084630` scales the visible camera interval from its current near plane.
The shadow span grows with that near plane, stays within the camera far plane,
and remains representable when uploaded as float32. The direct cascade builder
keeps its existing API and source comparison fixtures.

## Regression checks

The regression drives the real globe controls outward and inward from both
ground-facing and horizon-facing cameras, with shadow scales of 0.25 and 1.
Before the fix, all four paths failed the useful shadow-span check. After it,
all seven focused frame and cascade tests passed. The complete geospatial suite
passed 219 tests with 21 optional skips.

`examples/planet/integration_test/cloud_orbit_test.dart` uses Planet's preset
controls, source cloud assets, atmosphere, a coarse ellipsoid ground mesh and an
extra 64 MiB GPU buffer. It sends trackpad and touch events through Flutter's
input path, crosses the failing orbital clip range, changes cloud and shadow
quality in orbit, returns toward the surface, and resizes to portrait. Each
quality replacement must finish its 16-frame temporal cycle. These are injected
gestures on the native runtime, not a physical finger test.

The fixture has no provider tiles or network load. Its buffer adds resource
pressure but does not reproduce tile decoding, eviction or city geometry.

[Recorded native runs](cloud-orbital-zoom.json) cover the clipping fix and the
fixture hash recorded in that file. Concurrent changes to raycaster caching and
cloud history are outside this compiled test snapshot.

| Profile run | Presented frames | Result |
| --- | ---: | --- |
| macOS, Metal | 499 | Passed |
| iPhone 16 Pro, Metal | 602 | Passed |

Both runs reached a camera radius of 27.36 million metres, with the near plane
at 19.38 million metres. Both completed with zero sessions, renderers, retiring
resources, held drawables and readback bytes. The iPhone test paused while the
app was in the background, then completed after Planet returned to the foreground.
The iPad check is pending an unlocked device.

## Limits

This fixes the reproduced clipping failure. It does not establish that every
reported app exit or GPU driver fault has the same cause. Two saved macOS
process crash reports from earlier runs point to Flutter's accessibility bridge,
not the cloud renderer. No change to that Flutter engine code is included here.

Flutter remains pinned to 3.47.5, with Impeller and native Metal enabled. GPU
execution time and matched Takram performance are not measured by this fixture.
