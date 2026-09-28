# gpu3d_gltf

This optional Dart package contains the glTF decoder for `gpu3d`. It depends on
the public core and can run without Flutter or a GPU device.

The current checkpoint provides internal JSON/GLB parsing, buffer resolution,
typed accessor decoding and bounded worker isolates. `GltfLimits` lets you set
metadata and accessor limits alongside the core asset budgets. Public model
requests, model templates and rendering integration are still in progress.

## Decoder contract

The parser checks GLB framing, JSON depth and token counts, duplicate properties,
versions and required extensions before converting document data. It rejects
unsupported required extensions and records warnings for optional extensions.
No extension is enabled by default at this checkpoint.

Buffer references use `AssetDecodeContext`, including its URI policy, effective
base URI, cancellation and source limits. Embedded buffers use bounded base64
decoding. Accessors check ranges before allocation and handle sparse values,
interleaved strides, normalized integers and matrix column padding. Integer
indices keep their original precision.

Each caller isolate admits two workers and up to sixteen queued jobs. Cancellation
removes queued work or terminates an active isolate. Release tests compile a
standalone executable to exercise data, errors and cancellation across isolates.

You can run the package checks from the workspace root:

```sh
dart test packages/gpu3d_gltf/test
```

The fixtures follow the [Khronos glTF 2.0 specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html).
Passing parser tests does not establish material, scene or extension rendering
support. Track that work in [the resource and renderer plan](../../docs/superpowers/plans/2026-09-26-03-resources-and-renderer.md).
