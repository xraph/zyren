# Pipeline preparation worker

Build the CPU worker from the workspace root:

```sh
cargo build --locked --manifest-path packages/zyren_pipeline/native/Cargo.toml
cargo test --locked --manifest-path packages/zyren_pipeline/native/Cargo.toml
cargo clippy --locked --manifest-path packages/zyren_pipeline/native/Cargo.toml -- -D warnings
```

Rust 1.97.1, meshopt 0.6.2 and basisu_c_sys 0.9.1 are pinned. The lockfile records
transitive dependencies. Configure `PipelinePreparer` with the absolute executable
path. The worker is a desktop build tool, separate from the native renderer ABI.
No GPU or network connection is opened. Hosts distribute prepared bundles to
mobile devices; they do not need to run the encoder there.

One bounded JSON request arrives on stdin, one result leaves on stdout, then the
process exits. The Dart adapter checks the returned tool version, validates mesh
data and decodes textures through your existing codec. It limits concurrent
workers, input/output bytes and elapsed time. Cancellation kills and drains the
child. These are admission limits, not a process RSS sandbox. The executable is
trusted host configuration and is never accepted as an agent argument.

Mesh preparation optimizes triangle order. LOD uses absolute object-space quadric
error with locked borders and attribute-aware simplification. Positions, normals,
UVs, tangents, colors, joints, weights and morph deltas retain their original
values and vertex indices. Process each material/source primitive separately.
Skin/morph inputs and explicit per-face source IDs use lossless reordering only.
Their result reports a protection reason when you request LOD. Generated static
LODs keep source-object identity but cannot promise exact source-triangle IDs.
The cache metric is a simulated 16-entry vertex cache, not a GPU measurement.

Texture preparation accepts straight-alpha RGBA8 and emits ETC1S or UASTC KTX2.
Color transfer, quality, effort and clamp mip generation are explicit. Encoding
uses one thread and disables UASTC Zstd for repeatable local builds with the
existing runtime codec profile. Cross-architecture byte identity is unverified. Alpha channels are retained; mip filtering is independent
per channel and does not preserve alpha-test coverage. Keep original pixels in
your bundle for rebuilding or different preparation policies. Choose runtime
transcode targets from actual device capabilities, with RGBA8 as the fallback.
