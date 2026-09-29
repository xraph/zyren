# Compression fixtures

You can regenerate these synthetic fixtures from `packages/gpu3d_native/native`:

```sh
cargo +1.97.1 run --example make_meshopt_fixture
cargo +1.97.1 run --example make_draco_fixture
cargo +1.97.1 run --example make_basis_fixtures
```

`triangle.meshopt` contains three float32 positions. `triangle.glb` adds
compressed triangle indices and a placeholder fallback buffer. Both use the
pinned meshopt encoder and contain no provider data.

`quad-sequential.drc` and `quad-edgebreaker.drc` encode the same four-vertex
quad with positions, normals and UVs. Attribute IDs are 77, 8 and 21 so the
tests exercise lookup by unique ID rather than attribute order.

`colors-etc1s.ktx2`, `colors-uastc.ktx2` and `colors-zstd.ktx2` encode an 8x8
red/blue image with partial alpha and four authored mip levels. The generator
uses the pinned Basis Universal encoder with synthetic pixel data. These files
contain no provider imagery.
