# Meshopt fixtures

You can regenerate these synthetic fixtures from `packages/zyren_native/native`:

```sh
cargo +1.97.1 run --example make_meshopt_fixture
```

`triangle.meshopt` contains three float32 positions. `triangle.glb` adds
compressed triangle indices and a placeholder fallback buffer. Both use the
pinned meshopt encoder and contain no provider data.
