# Native camera projection

You can now use perspective zoom, orthographic bounds, world-point projection,
unprojection and picking rays through the public `zyren` camera API. These
operations stay in the general core. They do not depend on an ellipsoid or the
geospatial plugin.

`PerspectiveCamera.fieldOfView` is the vertical angle in radians. Its `zoom`
scales the projection. `OrthographicCamera` takes explicit left, right, bottom
and top bounds; resizing a viewport does not silently change them. The camera
lab updates its bounds to preserve vertical scale when you resize the view.
Both cameras expose `setClippingRange` so you can replace disjoint near/far
ranges atomically. Orthographic near can be zero; perspective near must be
positive. Invalid edits leave the previous projection intact.

`projectPoint` and `unprojectPoint` use normalized X/Y coordinates from -1 to 1
and native depth from 0 to 1. The view-projection matrix consumes positions
relative to the camera, preserving the existing large-coordinate rendering
contract. The point methods accept and return world coordinates.

`rayFromNdc` returns a normalized world ray. Perspective rays originate at the
camera. Orthographic rays originate on the camera plane with parallel
directions, matching Three's Raycaster. An application can pass this ray to its
own intersection routines. Mesh picking and acceleration structures remain
unimplemented.

## Reference and checks

`tool/camera_reference.mjs` runs Three.js 0.184.0 directly, using perspective and
orthographic cameras plus Raycaster. It converts Three's OpenGL depth to the
native 0..1 convention. The committed fixture has 36 configurations and 108 ray
samples: both projections, three zooms, three viewport aspects, off-center
bounds, tilted up vectors, and ordinary/Earth-scale world positions.

| Quantity | Maximum observed difference | Test limit |
| --- | --- | --- |
| Camera-relative projection matrix | 3.56e-15 | 1e-12 |
| Projected normalized position | 2.04e-9 | 5e-9 |
| Native project/unproject round trip | 2.74e-14 scene units | 1e-9 |
| Ray origin | 9.32e-10 scene units | 5e-9 |
| Unit ray direction | 1.04e-10 | 5e-10 |

The largest reference differences come from Three's world-coordinate matrix
operations at Earth-scale positions. Native projection subtracts the camera
origin first. Tests also check clipping depth, parallel orthographic rays,
zoom, revision notifications, atomic updates and invalid inputs.

```sh
node tool/camera_reference.mjs /tmp/geospatial-reference \
  packages/zyren/test/fixtures/three_cameras.json
cd packages/zyren
dart test test/camera_projection_test.dart
```

The reference workspace uses the exact dependencies in [numerical.md](numerical.md).
Node remains a development tool; it is not part of the native application.

Camera pose still follows zyren's existing world-space position, target and up
contract. Parented cameras, view offsets and custom asymmetric perspective
frusta are not covered. OrbitControls, GlobeControls and projection transition
animation are separate work. The [camera lab](native-camera-lab.md) exercises
instant projection changes while retaining position, target and rolled up.
