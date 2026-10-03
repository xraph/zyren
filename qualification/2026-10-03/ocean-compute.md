# Ocean native compute checks

Run `RUN_NATIVE_GPU=1 fvm dart test test/waves --concurrency=1` from
`packages/zyren_geospatial_ocean` on a native host. These checks use the public GPU
scope and graph APIs, with no water-specific native backend changes. All 19
wave tests passed with native GPU execution enabled. Package analysis and
boundary checks passed.

The macOS 4 x 4 and 8 x 8 Stockham inverses match the independent direct complex
DFT within 2e-5. Packed displacement, slopes, water velocity and Jacobian match the
canonical CPU reference within 3e-5 for the fixture, including a timestamp beyond
1e10 seconds. Finite differences independently check reference derivatives.

Lifecycle checks force a native allocation failure after partial candidate
allocation, cancel both before and during replacement, reject an oversized logical
budget, switch grid sizes repeatedly and close during accepted work. Failed
replacements preserve the previous snapshot and its bytes. Closing returns owned
native allocation counts to zero. Oversized custom spectrum output is rejected
before publication.

A one-band sweep produced these results on this host:

| Grid | Owned buffer/texture payload | Cold evaluation |
| --- | ---: | ---: |
| 64 x 64 | 852,176 bytes | 425 ms |
| 128 x 128 | 3,408,112 bytes | 24 ms |
| 256 x 256 | 13,631,760 bytes | 19 ms |
| 512 x 512 | 54,526,256 bytes | 23 ms |

The first evaluation includes lazy canonical coefficient generation. Later rows
reuse that CPU state but allocate and compile a new grid. These numbers describe
one compute-only run, without scene rendering or the readback that follows each
evaluation. They are not sustained frame times, preset guarantees or physical GPU
residency measurements. Mobile, Vulkan and DX12 qualification remain pending.

The numerical state uses Phillips model version 1, exact unsigned SplitMix64 seed
arithmetic and CPU Box-Muller draws. An independent Python calculation reproduced
the 8 x 8 coefficient hash recorded in the package README. Globe mesh seams, water
optics, buoyancy and professional visual acceptance belong to subsequent tasks.
