# Compressed assets

Flutter's default `SceneRuntime` supplies native Draco, meshopt and Basis/KTX2
decoders. You can also inject them into a standalone Dart asset scope:

```dart
final assets = AssetScope(services: AssetServices(
  resolver: const NativeSourceResolver(),
  bufferDecoder: const NativeBufferDecoder(),
  meshDecoder: const NativeMeshDecoder(),
  textureDecoder: const NativeTextureDecoder(),
));
final model = await assets.load(Gltf.uri(modelUri)).result;
```

These are CPU services. They do not create a renderer. The core defines the
contracts; the native package implements them; the glTF plugin selects them from
declared extensions. A required extension without its decoder fails early. An
optional extension can use its ordinary fallback.

| Encoding | Native implementation | Returned data |
| --- | --- | --- |
| EXT_meshopt_compression | meshopt 0.6.2 | Attribute or index buffers, including supported filters |
| KHR_draco_mesh_compression | draco-core 2.2.1 | Validated indices and attributes identified by unique IDs |
| KHR_texture_basisu | basisu_c_sys 0.9.1 | RGBA8 pixels from ETC1S, UASTC or UASTC/Zstd KTX2 |

Basis preserves authored mips, alpha and the declared transfer function. Its
current GPU upload is RGBA8. It does not provide BC, ETC or ASTC GPU residency.
The supported KTX2 profile is two-dimensional LDR, with one face and no array,
video or animation payload. Unsupported layouts and conflicting material color
spaces produce a field error rather than an approximation.

Each native codec accepts at most 16 MiB of encoded input and 64 MiB of decoded
payload. Draco also limits vertices, triangles and attribute counts. Meshopt
validates the declared stride and output length before allocation. Image and
Basis calls share the existing 256 MiB workspace admission pool; mesh decodes
have their own bounded admission. These limits describe payload and admitted
working memory, not total process RSS.

Asset jobs serialize CPU decode admission against their remaining decoded-byte
budget. Input snapshots belong to the worker until physical completion. Cancelling
the consumer prevents publication and waits for cleanup; it does not interrupt a
native codec midway through a call. Two calls per native codec may be active.

Real fixtures cover all three Basis encodings, both Draco mesh methods, meshopt
indices/filters and an independently encoded Khronos Box. Tests check truncation,
hostile metadata, limits, input mutation, cancellation, cleanup and fallback.
A Metal fixture loads compressed glTF, renders pixels and verifies that removing
the model releases its scene resources. Flutter's default services decode all
three formats before any view or renderer is attached.

This run qualifies CPU decoding and Metal rendering on macOS. Other native
platforms still need their build and device runs. Fixture regeneration commands
and provenance are in `test_assets/compression`; redistribution notices are in
`docs/licenses/compression`. Dependency changes stay pinned in `Cargo.lock`.
