# HDR assets

You can load an HDR image before creating a renderer. Flutter controllers include
a native HDR decoder in their default services:

```dart
final image = await controller.assets.load(
  AssetRequest(
    uri: Uri.parse('asset:///environments/studio.hdr'),
    loader: const HdrImageLoader(),
  ),
).result;
```

For plain Dart, create an `AssetScope` with `NativeSourceResolver` and
`NativeHdrImageDecoder` in `AssetServices.hdrImageDecoder`. You can use the same
scope for models and images. Pending requests share work when their services,
source, version and loader options match.

`HdrImageData` owns immutable, top-down RGBA32F pixels in linear sRGB. Its
constructor copies your input. RGB values can exceed one, alpha stays in [0, 1],
and every component must be finite. Releasing the asset drops the scope's hold;
any Dart reference you keep remains usable.

Upload through your resource scope:

```dart
final texture = await resources.createTexture(TextureDescriptor(
  width: image.size.width,
  height: image.size.height,
  format: TextureFormat.rgba16Float,
));
await resources.writeTexture(texture, image.toRgba16Float());
```

Half-float conversion rounds to nearest, with ties to even. Values above 65504
throw. If you need to fit brighter data, pass an explicit `scale` to
`toRgba16Float`; it changes RGB only. This is a lighting-scale decision. Display
exposure and tone mapping remain in `ColorPipeline` at the end of rendering.

## Native RGBE profile

The decoder accepts `#?RADIANCE` and `#?RGBE` files with
`FORMAT=32-bit_rle_rgbe`. Flat, legacy RLE and component RLE scanlines support all
eight axis orientations and produce opaque pixels. Headers are limited to 64 KiB.
Truncated data, invalid run lengths and trailing bytes fail with typed errors.

You supply linear-sRGB environment assets. Missing `PRIMARIES` uses that
convention; explicit non-sRGB primaries, XYZE and non-square pixels are rejected.
This differs from the Radiance specification's default primaries. Stored pixel
values are preserved, and `EXPOSURE`/`COLORCORR` are not applied again. This API
does not reconstruct physical radiance from header corrections.

The [Radiance file specification](https://radsite.lbl.gov/radiance/refer/filefmts.pdf)
defines the header, orientation and scanline encodings. This bounded decoder is
implemented in the native runtime without adding another codec dependency.

`ImageDecodeLimits` applies to both image decoders. The hard profile allows
16 MiB encoded input, 64 MiB decoded pixels, dimensions up to 4096 and 128 MiB of
estimated native working storage per decode. RGBA32F consumes 16 bytes per pixel,
so a 4096 by 2048 image exceeds the decoded limit. PNG/JPEG and HDR decodes share
the native 256 MiB admission budget. Dart copies are outside that reservation.

`AssetDecodeContext.decodeHdrImage` also shares the job's decoded-byte budget
with byte images and geometry. Cancellation prevents late results from reaching
a closed scope. A running native decode finishes within its limits before its
storage is released.

Use [EnvironmentLighting](environment-lighting.md) to prepare diffuse and
specular lighting from this image. Uploading an HDR texture alone does not bind
it to a scene.
