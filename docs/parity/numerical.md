# Geodesy, tiling and camera fixtures

You can run this slice without Flutter or a GPU. The geospatial package imports
only public `zyren` APIs. The native renderer still has no atmosphere or cloud
pipeline, and these numerical tests do not establish rendered story parity.

The fixture generator loads the actual pinned TypeScript modules, checks their
Git blob hashes, and transpiles them in a temporary Node environment. It does
not copy the Dart implementation into a second language. The resulting JSON
records every loaded source module and the dependency versions.

## Reproduce

Use the repository's Flutter 3.47.5 Dart SDK. Your global Flutter may point to
an older SDK.

```sh
mkdir -p /tmp/geospatial-reference
npm install --prefix /tmp/geospatial-reference --save-exact --ignore-scripts --no-audit --no-fund \
  typescript@5.9.2 three@0.184.0 tiny-invariant@1.3.3
node tool/geospatial_reference.mjs /path/to/three-geospatial-main \
  /tmp/geospatial-reference packages/zyren_geospatial/test/fixtures/upstream_core.json
cd packages/zyren_geospatial
dart test
```

Node and TypeScript are fixture-generation tools only. The shipped package and
its tests consume plain JSON and run in Dart; no browser or JavaScript engine
is part of the native application.

## Implemented operations

- `Geodetic`: conversion, value equality, list serialization, immutable copies
  and explicit source-compatible normalization. Longitude is now retained as
  supplied, including positive pi. This changes the earlier alpha constructor,
  which automatically wrapped longitude. Explicit normalization matches the
  source's single addition of 2pi below -pi; it is not a general angle wrapper.
- `Ellipsoid`: derived radii, flattening/eccentricity, reciprocal radii,
  projection, normals, ray intersection, ENU/NUE matrices, osculating center
  and horizon normal. Projection uses the source's radial fallback near the
  center and a bounded Newton iteration elsewhere.
- `GeographicRectangle`, `TileCoordinate`, `TilingScheme`: bounds, interpolation,
  equality/copies, lists, parent and ordered descendants, size, lookup and
  rectangles. Tile Y starts at the south edge. Rectangle interpolation starts
  at the north edge. That distinction follows the source.
- `PointOfView`: distance/pitch clamps, heading/pitch/roll decomposition,
  quaternion and world-space camera pose, camera application and reconstruction
  at the first ellipsoid intersection. A sky-facing view returns null.

## Numerical acceptance

| Comparison | Cases | Maximum observed error | Test bound |
| --- | --- | --- | --- |
| ECEF position | 200 | 8.34e-9 metres | 2e-8 metres |
| Surface projection | 200 | 2.09e-9 metres | 2e-8 metres |
| Inverse height | 200 | 1.50e-8 metres | 2e-8 metres |
| Inverse latitude at poles | Included above | 1.50e-8 radians | 2e-8 radians at exact poles, 1e-12 elsewhere |
| Tile coordinates | 60 | Exact integer match | Exact |
| Rectangle extents/interpolation | 3 extents | Within 1e-14 radians | 1e-14 radians |
| PointOfView eye/orientation | 24 | Eye within 1e-8 metres; orientation dot within 1e-12 | Same bounds |
| Reconstructed surface hit | 24 | 3.40e-6 metres | 5e-6 metres |
| Reconstructed distance | 24 | 2.78e-6 metres | 5e-6 metres |
| Reconstructed heading | 24 | 1.68e-8 radians | 2e-8 radians |

The pole difference comes from upstream's `asin(normal.z)` and native
`atan2(z, horizontalLength)`. Native retains the existing stable inverse.
Upstream camera extraction unprojects a point and subtracts the ECEF eye;
zyren uses its explicit target direction. That subtraction accounts for the
micrometer difference. Quaternion sign is ignored because q and -q represent
the same rotation.

## Deliberate API differences and remaining gates

Values use immutable Dart copies instead of mutable result arguments. Inputs
must be finite, latitudes stay within their physical range, and invalid
ellipsoid radii throw. The exact center has no projection. At an exact ECEF
pole, the native ENU basis chooses longitude zero; the source can produce a
degenerate basis there. The fixtures also cover coordinates near the poles.

The upstream tiling implementation unconditionally adds 2pi to longitude for
a crossing rectangle, clamps only upper bounds, and interpolates raw rectangle
endpoints. Those quirks are retained and tested. Native sizes use ordinary
integer multiplication for levels 0 through 30, without JavaScript's signed
32-bit shift overflow. Negative levels remain possible as the parent of level
zero, but cannot be passed to `getSize`.

zyren's camera `up` is a world-space vector used with `target`. The source has
a local up vector and quaternion. Fixtures construct an ordinary Y-up Three
camera and compare its transformed world up with the native pose. Arbitrary
local-up conventions, parented camera extraction and orthographic reconstruction
remain unverified. Do not mark G03 complete until those contracts are resolved.

This slice passes 17 package tests, analyzer and the package-boundary guard.
No native visual or physical-device comparison is implied by that result.
