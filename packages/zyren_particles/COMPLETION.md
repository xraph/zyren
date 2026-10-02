# Particle implementation checks

You can follow implementation and qualification here. Platform results apply to
the named devices. The package remains unpublished.

| Requirement | Implementation | Verification |
| --- | --- | --- |
| Validated settings and playback lifecycle | Implemented | Clock, pause, resume, drain, reset and reattachment regressions pass |
| Fixed ticks, bursts, prewarm, seeds and overflow | Implemented | Reference results agree at 30, 60, 120 and 144 Hz |
| Shapes, surface sampling and transform spaces | Implemented | Native surface images, birth transforms and large world coordinates pass |
| Curves, gradients, forces and collisions | Implemented | Noise GPU/reference comparison and rebased world collision regressions pass |
| Native GPU simulation and reference fallback | Implemented | State tolerance 0.00001; 24 native images compare both paths |
| Billboards, oriented quads, stretch, meshes and ribbons | Implemented | Every appearance and blend combination renders on Metal |
| Texture atlas, blending, depth and sorting | Implemented | Atlas images, camera reversal and visible depth-write tests pass |
| Soft depth intersections | Native mesh API has no sampled scene depth binding | Explicit UnsupportedError tested; feature unavailable |
| Independent scenes, disposal and restoration | Implemented | Two native views, partial attach rollback, atomic configuration and zero resource counters pass |
| Maximum capacity | Implemented, 65,536 particles | Full-capacity GPU sort and explicit live-count readback pass |
| Dedicated native examples | Implemented in examples/particles | macOS and Android interaction tests pass at desktop and narrow constraints |
| Tests, analysis, format and package boundaries | 19 package tests pass; analysis and format clean | Native material/graph regressions pass; strict Clippy has four unrelated warnings |
| Metal execution | Verified on Apple M3 Max | Package images and final app interaction test pass |
| Android Vulkan execution | Verified on Pixel 9 Pro | Final app interaction test passes with zero frame readback bytes |
| iOS | Simulator and signed physical-device builds passed | Physical-device interaction blocked by wireless VM-service discovery |
| Linux Vulkan and Windows DX12 | Shared native backend, build targets supplied | No matching hardware in this session |
