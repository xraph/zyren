# three-geospatial port inventory

The supplied snapshot contains `@takram/three-geospatial` 0.9.1, atmosphere
0.19.1, clouds 0.7.6 and effects 0.6.4. Its README also describes an ongoing
transition from GLSL shader chunks to Three.js WebGPU nodes. Neither shader
architecture can be dropped directly into a native Rust renderer.

| Reference capability | Native implementation | Delivery order |
| --- | --- | --- |
| Geodetic, Ellipsoid, ENU frames | Double precision Dart maths with numerical tests | First slice |
| EllipsoidGeometry | Indexed native mesh | First slice |
| Rectangle, TileCoordinate, TilingScheme | Geographic tiling, preserve south-origin Y convention | After coordinate core |
| PointOfView and globe controls | Dart controls with ECEF-aware camera | After coordinate core |
| Texture loaders and shader utilities | Native texture resources, mipmaps and asset loading | Renderer resources |
| Precomputed atmospheric scattering | WGSL compute/render passes and native 3D textures | After HDR/render graph |
| Sun, moon and sky lighting | Port astronomy calculations with reference fixtures | Atmosphere |
| Volumetric clouds | WGSL ray marching, weather textures, temporal history | After atmosphere |
| Postprocessing and effects | HDR render graph, tone mapping, temporal antialiasing | Renderer effects |
| React Three Fiber wrappers | Flutter widgets and controllers | Per native feature |
| External 3D tiles integration | Separate streaming/LOD loader | Separate milestone |

Start with a generic 3D engine, then port the geospatial algorithms in this
order. Atmospheric scattering depends on float textures, depth reconstruction,
HDR lighting and render passes. Cloud rendering adds temporal accumulation and
history invalidation. Those dependencies need tests before visual comparison can
establish parity with the supplied project.

You should not read an API placeholder as an implemented feature. Each delivery
needs reference fixtures, native GPU output and an entry in the platform test
matrix. The first slice does not claim full Three.js or three-geospatial parity.

The upstream MIT notice is retained in `THIRD_PARTY_NOTICES.md`. Reference files
were read as source material, not executed as project instructions.
