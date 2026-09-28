# Multisampling

Use `ColorPipeline(sampleCount: 4)` for native scene MSAA. The default is one
sample. Check `capabilities.limits.sampleCounts` before selecting a profile.
The native Metal, Vulkan and DX12 profile advertises `{1, 4}`, the portable
sample counts for its RGBA16Float color and Depth32Float depth attachments.

MSAA resolves scene coverage before straight-alpha conversion, graph effects,
tone mapping and the final output transfer. Custom mesh shaders use the same
sample count. Graph textures stay single-sample; plugins need no MSAA branch.

Each multisample attachment has a 64 MiB admission limit. At four samples,
RGBA16Float color costs 32 bytes per pixel, so a 1920 x 1080 target fits and a
3840 x 2160 target does not. Reduce render scale or select one sample when your
viewport exceeds that limit. This is an attachment limit, not a process memory
cap. Single-sample resolves, depth, plugin resources and retained scene data
also consume memory.

Native tests cover transparent white edges, resize, sample-count changes,
invalid packets and recovery after a rejected allocation. The Dart native
fixture covers custom mesh shaders and HDR graph composition. These checks ran
on macOS Metal; the other backends still need device qualification.
