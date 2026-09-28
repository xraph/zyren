# Texture history

Use `frame.createHistory()` inside a shared effect builder when your shader needs
the previous frame. You get two logical texture roles and a uniform buffer:

```dart
final history = await frame.createHistory(label: 'trail');
return GraphEffect(
  output: history.current,
  passes: [
    RenderPassDescriptor(
      name: 'trail blend',
      program: program,
      color: ColorAttachment(history.current),
      bindings: ShaderBindings([
        TextureBinding.sampled(0, frame.input),
        TextureBinding.sampled(1, history.previous),
        BufferBinding.uniform(2, history.uniforms),
      ]),
      reads: [frame.input, history.previous, history.uniforms],
      writes: [history.current],
    ),
  ],
);
```

Compile `program` in your plugin's attachment scope. Include `TextureHistory.wgsl`
in its source, then bind the metadata with the same slot used above:

```wgsl
@group(0) @binding(2) var<uniform> history: TextureHistoryState;
```

The metadata occupies 16 bytes. `validFrames` and `generation` are unsigned
32-bit integers, followed by eight padding bytes. When `validFrames == 0u`, seed
the output from this frame and ignore previous pixels. Resetting history does
not clear either texture. Your shader must observe this rule.

You can see the complete shader in the independent
[temporal blend plugin](../../examples/shader_lab/effects_plugin/lib/src/temporal.dart).
It blends alpha-weighted linear color, then returns straight alpha for the next
effect. It demonstrates accumulation; TAA, motion vectors and depth rejection
remain renderer work in plan 03, task 8.

## Ownership and submission

The engine owns history for one view. Each history allocates two textures at the
physical frame size, using the input format unless you supply `format`. History
allocations use the device's normal resource budget. Plan for both the active
and candidate texture sets during resize or a graph edit.

Use `previous` and `current` only in graph declarations. The engine compiles two
variants with their physical bindings exchanged, then alternates those variants
after successful backend completion. Retained aliases are exchanged too. This
needs two compiled graphs but shares cached pipelines, with no per-frame
shader compilation, texture copy or CPU readback. All histories in the shared
graph use one metadata upload per frame and advance together.

`previous` is read-only. You must produce `current` in the graph and store every
render attachment write to it. Don't declare `current` as an imported input.
The engine imports `previous` and the metadata automatically. For compute, supply
`TextureFormat.rgba8Unorm` and both `TextureUsage.sampled` and
`TextureUsage.storage`; declare storage texture capabilities on your plugin.

Both variants must compile before a candidate replaces the active graph. Failed
edits retain the last valid graph and history when its dimensions still match.
A failed render leaves the history index and count unchanged, so retry writes
the uncommitted current target again. History commits at backend completion,
before plugin `afterRender` hooks and Flutter presentation. It does not certify
that a frame reached the display.

The history scope stays alive until its compiled graphs retire. Temporary
`frame.resources` close after compilation, while attachment resources last until
the plugin detaches. Keep persistent effect parameters in `context.resources`.

## Resetting samples

Call `controller.invalidateHistory()` after a camera jump or a scene change that
makes old pixels unusable. A plugin can call `context.graph.invalidateHistory()`.
Both request a frame. Headless callers use `engine.invalidateHistory()` and then
drive their next render as usual.

Successful graph rebuilds, physical resize, camera replacement, projection changes
and engine recreation reset history automatically. Ordinary camera movement
preserves it; your temporal algorithm decides how to reproject or reject those
samples. Camera cuts need an explicit reset. All histories in the view reset
together, and the next shader invocation sees zero valid frames and a new
generation. No allocation is required for an explicit reset.

A reset during metadata upload defers that frame. A reset during backend
submission prevents its completion from advancing the new generation. Camera and
scene snapshots are captured before asynchronous graph preparation, so the
projection used to decide validity matches the submitted frame.

`context.graph.state.historyFrames` counts successful frames since the last
reset, saturating at `0xffffffff`. `historyGeneration` wraps at 32 bits and is
useful for shader-local reset decisions. Independent views have separate texture
pairs, counters and generations even when they share a scene.

History management currently belongs to shared effect builders. If you select a
manual `context.frameGraph`, you own its temporal resource lifecycle.
