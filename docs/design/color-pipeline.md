# HDR color and tone mapping

You can preserve bright lighting through scene rendering and effects with a
per-view `ColorPipeline`. The native renderer uses linear RGBA16Float internally
and converts the result to SDR for Flutter or image capture.

```dart
final controller = SceneController(
  colorPipeline: ColorPipeline(
    toneMapping: ToneMapping.acesFilmic,
    exposure: 1,
  ),
);

// Requests a frame. Scene materials and texture images stay resident.
controller.colorPipeline = ColorPipeline(exposure: .8);
```

Import `flutter_zyren/flutter_zyren.dart` for this example. Dart callers pass
`colorPipeline` to `SceneEngine.renderFrame` or `FrameSubmission.capture`. Each
submission captures its immutable settings, including when you select a graph
later with `withGraph`. Two views can share scene resources with different
exposures. Set the pipeline to `null` to use the existing RGBA8 profile.

## Curves and exposure

| Setting | Behavior |
| --- | --- |
| `ToneMapping.linear` | Multiply linear color by exposure, then clamp for SDR |
| `ToneMapping.reinhard` | Apply `x / (1 + x)` to exposed linear channels |
| `ToneMapping.acesFilmic` | ACES fitted curve with Three.js's viewing exposure adjustment |
| `exposure` | Finite linear multiplier in `[0, 1e6]`, default `1` |

The default curve is ACES filmic. Its matrices, fit and `1 / .6` viewing adjustment
follow [Three.js's tone-mapping shader](https://github.com/mrdoob/three.js/blob/dev/src/renderers/shaders/ShaderChunk/tonemapping_pars_fragment.glsl.js).
The license is retained in [third-party notices](../../THIRD_PARTY_NOTICES.md).
This is an SDR rendering curve, not an ACES interchange or HDR-monitor profile.

Tone mapping runs once, after scene transparency and graph effects. It operates
on straight linear RGB. Output transfer follows the curve, and native presentation
premultiplies at the compositor boundary. Readback keeps straight alpha. The curve
does not change coverage. Exposure edits need no geometry/image uploads or effect
graph rebuild; switching between LDR and HDR rebuilds the shared graph and resets
its texture history. History retains linear samples when exposure changes.

## Effects and custom shaders

Shared effect builders receive an RGBA16Float input when HDR is enabled.
`createColorTexture` and `createHistory` inherit that format. Their color outputs
must preserve it; an effect that returns RGBA8 fails explicitly. You can still
allocate other formats for data such as masks, where narrowing is intentional.

For an explicit frame graph, supply RGBA16Float `sceneColor` and `output` textures.
The renderer rejects incompatible endpoints before rendering. You own intermediate
precision in a manually assembled graph. Output shaders should return straight
linear values without a second tone map or sRGB transfer.

Built-in materials and custom mesh shaders render into the same selected scene
format. Custom shaders retain their existing uniform and binding interfaces. HDR
allows their output above one to survive until effects and the terminal curve.

## Float resources and bounds

`TextureFormat.rgba16Float` is available through `TextureDescriptor` and resource
scopes. You can sample it, render to it, bind it as a write-only storage texture,
or upload/read its raw texels. WGSL storage declarations use `rgba16float`.

| Format | Texel bytes | Storage binding |
| --- | --- | --- |
| `rgba8Unorm` | 4 | Supported |
| `rgba8UnormSrgb` | 4 | Rejected |
| `rgba16Float` | 8 | Supported |

Float texels contain four little-endian IEEE float16 channels. Uploads must match
the selected mip's byte count. Native copies align staging rows internally and
return tightly packed bytes. Mip and residency accounting use eight bytes per
texel. Each resource and internal HDR color attachment is bounded to 64 MiB.

The byte-image API, `TextureImage.rgba`, still accepts RGBA8 formats only. Use
resource scopes for float data; an HDR image decoder and environment-map assets
remain separate work. Half-float precision has a finite maximum of 65504. Keep
custom shader and effect intermediates in that representable range. The terminal
curve clamps RGB to `[0, 65504]` before exposure, then emits SDR values.

`RenderFeature.hdrColor` advertises the native color pipeline. `SceneEngine`
rejects unsupported adapters before submission. This profile has GPU evidence
on host Metal and a physical Pixel's Vulkan backend. Other devices still need
the platform qualification recorded in [verification](../verification.md).

## Run it

The [PBR lab](../../examples/shader_lab/README.md) exposes ACES, Reinhard and Linear
selectors alongside Exposure. The standalone native PBR example also selects
ACES. Reference tests cover bright channels, transparent overlap, alpha, custom
shaders, effect ordering, texture storage, invalid packets and independent views.

Environment reflections, shadows, bloom, multisampling, additional tone curves
and standard glTF qualification remain open. Internal HDR does not close those
renderer gates.
