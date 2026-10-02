# Particle implementation checks

You can follow implementation and qualification here. A checked implementation
row does not imply that every native platform has been tested.

| Requirement | Implementation | Verification |
| --- | --- | --- |
| Validated settings and playback lifecycle | Implemented | Clock regressions pass; plugin lifecycle qualification next |
| Fixed tick emission, bursts, prewarm, seeds and overflow | Implemented | Eight reference tests pass |
| Shapes, surface sampling and transform spaces | Implemented | Sphere, cone and transform regressions pass; surface qualification next |
| Curves, gradients, forces and collisions | Implemented | Curves and collision regressions pass |
| Native GPU simulation and reference fallback | Implemented | Metal state agrees with reference within 0.00001 |
| Billboards, stretch, mesh particles and ribbons | Implemented | Billboard and ribbon Metal render passes; remaining modes next |
| Texture atlas, blending and depth state | Implemented | Additive native material extension implemented; image regressions next |
| Soft depth intersections | No public mesh depth binding | Unsupported capability must throw |
| Independent scenes, disposal and restoration | Pending | Pending |
| Dedicated native examples | Pending | Pending |
| Tests, analysis, format and workspace boundaries | Pending | Pending |
| Metal execution and images | Pending | Pending |
| Vulkan and DX12 execution | Pending | Hardware qualification required |
