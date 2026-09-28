# Shader lab

Use `ShaderLabPlugin` to add two native HDR passes to a scene. The first changes
gain through a uniform buffer. The second adds a small spatial glow around
values above one. Set the scene's tone mapping before presentation.

A dependent plugin can require `shader-lab` and obtain `shaderLabControls` from
its `PluginContext`. Call `setGain(value)` to upload a new parameter and request
a frame. Attachment cleanup removes both effects and closes their GPU owners.

Run `RUN_NATIVE_GPU=1 fvm dart test` in this directory for the standalone native
consumer. Planet's native graph integration test also installs this package on
the presentation device. See [the effect contract](../../docs/design/scene-effects.md)
for color, history and allocation limits.


`RendererFixture` combines standard materials, a generated HDR environment,
directional and spot shadows, 64 mirrored instances and an emissive source.
`RendererProfilePlugin` enables ACES, FXAA, bloom and four samples when supported.
The standalone test shares this scene across two views and checks resource cleanup.
`tool/renderer_benchmark.dart` records explicit readback timings; set `RENDERER_RGBA`
to save its last 512x384 RGBA frame. Planet's `renderer_lab.dart` presents the same
fixture through the native host. See [renderer profiles](../../docs/renderer-capabilities.md).
