# Compression fixtures

You can regenerate these synthetic fixtures from `packages/zyren_native/native`:

```sh
cargo +1.97.1 run --example make_meshopt_fixture
cargo +1.97.1 run --example make_draco_fixture
```

`triangle.meshopt` contains three float32 positions. `triangle.glb` adds
compressed triangle indices and a placeholder fallback buffer. Both use the
pinned meshopt encoder and contain no provider data.

`quad-sequential.drc` and `quad-edgebreaker.drc` encode the same four-vertex
quad with positions, normals and UVs. Attribute IDs are 77, 8 and 21 so the
tests exercise lookup by unique ID rather than attribute order.
