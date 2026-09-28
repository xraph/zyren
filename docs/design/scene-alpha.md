# Transparent scenes

A new `Scene()` has a transparent canvas. Set a color when you want a background:

```dart
final scene = Scene();
scene.background = Color3.hex(0x243447); // Opaque fill.
scene.backgroundOpacity = .5;          // Half coverage.
scene.background = null;               // Clear canvas again.
```

`backgroundOpacity` defaults to one and accepts finite values from zero to one.
It affects the background fill, not the objects in the scene. Use a material's
`opacity` with `MaterialAlphaMode.blend` to make a mesh translucent. Both scene
properties trigger invalidation and are frozen when a frame is captured.

If you relied on the old dark default, assign `Color3.hex(0x101722)` explicitly.
The unpublished API now allows null in `Scene.background`.

## Color through the frame

Material shaders emit straight linear color. Hardware blending accumulates RGB
multiplied by alpha. When the background has less than full coverage, the renderer
uses a reusable attachment and divides by the accumulated alpha before supplying
`sceneColor` to your effects. Zero coverage resolves to transparent black.

Your effects read and write straight color, including when they change alpha.
Preserve `color.a` when an effect should leave coverage alone. A shader can emit
RGB with zero alpha; explicit capture preserves that straight output, while the
presentation boundary makes those pixels invisible.

`ReadbackOutput.image` contains straight-alpha RGBA8 sRGB bytes. The Flutter image
adapter preserves alpha metadata, packs padded rows and converts straight pixels
to premultiplied bytes without modifying your input. Already premultiplied images
pass through; opaque images ignore their stored alpha channel.

Native surfaces use premultiplied sRGB bytes. Multiplication happens after sRGB
encoding, so a half-covered linear red value of 0.25 produces about 69 in the red
byte, rather than 99. The output shader accounts for the hardware sRGB attachment
conversion. Metal layers allow alpha. Android selects premultiplied presentation
when available, or inherited RGBA presentation for Flutter's SurfaceProducer;
unsupported surface modes fail explicitly.

Presentation and explicit image readback use 8-bit output. Select
[ColorPipeline](color-pipeline.md) for RGBA16F scene accumulation and effects;
small alpha values follow the precision limits of the selected scene format.

## Cost and ownership

An opaque scene keeps the direct render path. A transparent scene adds one
full-screen resolve draw, included in `FrameStats.drawCalls` and `triangles`.
With effects, that resolve happens before the effect chain; the graph's existing
final output draw handles native presentation conversion. Neither native path
uses CPU readback for ordinary presentation.

The renderer owns one accumulation texture, reuses it at the same size and format,
and releases it on an opaque frame or renderer teardown. It follows the same GPU
retirement lifetime as the renderer's other internal targets. Scoped resource
statistics describe explicit resource allocations and exclude internal targets.

Binary scene opcode 18 adds background alpha after ambient intensity. Previous
opcodes and JSON packets without `background_alpha` retain opaque backgrounds.
Invalid alpha values fail before drawing or advancing the view baseline.

## Verification

Native pixel tests cover clear and fractional backgrounds, overlapping blended
meshes, resize, opaque transitions and alpha-changing effects. Metal texture tests
compare surface bytes with straight readback and assert zero presentation readback.
The physical Pixel integration captures the Flutter texture over white and checks
composited colors. Apple platform views are outside Flutter's RepaintBoundary
capture, so that test cannot establish macOS or iOS window-compositor pixels.
See [verification](../verification.md) for current platform coverage.

The boundary follows Flutter's [RGBA pixel contract](https://api.flutter.dev/flutter/dart-ui/PixelFormat.html)
and wgpu's [surface alpha modes](https://wgpu.rs/doc/wgpu/enum.CompositeAlphaMode.html).
