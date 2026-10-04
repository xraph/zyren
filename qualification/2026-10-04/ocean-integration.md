# Ocean host integration, 4 October 2026

W12 is in progress. The native host and lifecycle checks below passed on macOS
Metal. The [six-scene lab](ocean-lab.md) now runs on macOS. Geographic-data, performance and platform gates remain open.

## Host and visibility

The extension publishes canonical state, an owned sampler and an owned
presentation through the geospatial registry. Tests install the actual expanded
`scenePlugins` list and cover missing dependencies, duplicate providers, partial
factory failure, cancellation, cleanup and presentation failure recovery. A
hidden surface retains query access and does not advance the simulation clock.
Duplicate shared clock and simulation drivers are rejected.

A native foam fixture changes rendered pixels through the layer's shader switch
while its sampled wave displacement and underlying foam field remain identical.
The underwater test detaches the volume effect, verifies the unattenuated pixels,
then reattaches it and recovers identical attenuated output. These tests establish
functional controls, not visual acceptance.

## Native presentation and resize

The integrated native fixture uses a 32 metre synthetic sphere, six charts, one
zero-wind band and six root patches. It applies surface, foam and underwater
visibility through the host. Failed quality admission preserves the current view;
the next frame recovers. A successful request changes the native grid from 4 to 8.

One hundred subsequent viewport replacements alternate between 32 by 16 and
24 by 16 pixels. Every replacement renders the native water and boundary pass.
Each size returns to the same counters:

| View size | Registry allocations | Registry payload bytes | Live graphs | Mesh bindings |
| --- | --- | --- | --- | --- |
| 32 by 16 | 179 | 232,624 | 24 | 12 |
| 24 by 16 | 179 | 231,600 | 24 | 12 |

After engine disposal, owned scene objects, effects, layers, services, registry
allocations, graphs and mesh bindings are empty. Registry payload is not measured
physical GPU residency. These small custom-profile fixtures are not a frame-rate
benchmark or an Earth-scale quality recommendation.

The generic plugin capture API separately passes early close, repeated close,
attachment cleanup and cancellation while a capture lease is being created.
It obtains captures on the scene's existing device and does not expose a second
backend to the application.

## Open qualification

- Professional visual review of the six-scene lab and motion captures.
- Provenance and distribution approval for a real global coast/bathymetry dataset.
- Desktop/mobile target performance and user visual acceptance.
- Android Vulkan, iOS Metal and Windows DX12 device runs.
