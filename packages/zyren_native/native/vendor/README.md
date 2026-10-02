# Native dependency patches

You can inspect the Metal change in
[metal-submission-status.patch](metal-submission-status.patch). We retain the
published `wgpu-hal` 30.0.1 source and its MIT/Apache-2.0 licenses. The original
crate archive has SHA-256
`b6b7fb58561a792bc237628ba0792e332de418fefe145f13b5ed8201e6d52f58`.

Metal fence completion includes failed command buffers in this version. The
public wgpu API also prevents mixing normal encoding with raw command access.
The patch exposes retained buffers from the latest queue submission, including
upload, wait and signal buffers. It holds at most one submission; taking the
list clears that queue storage. Callers must serialize submission and capture,
and may inspect the handles without encoding into or committing them.

The renderer takes this list immediately after submission. After its bounded
fence wait, every command must report `Completed` with no Metal error. Pending
or failed commands fail the renderer and prevent publication. This avoids a
race with asynchronous completion handlers. The native IOSurface and timeout
tests exercise the real queue path; the status regression covers errors.

Cargo pins wgpu to `=30.0.1` and applies this source through `[patch.crates-io]`.
Review the patch, imported texture ownership and GPU regressions together before
upgrading. Remove the local copy when upstream offers equivalent observable
submission results. The Metal patch does not alter Vulkan or Direct3D behavior.


## Vulkan image robustness

[vulkan-image-robustness.patch](vulkan-image-robustness.patch) backports the
capability fix from [wgpu PR 10291](https://github.com/gfx-rs/wgpu/pull/10291).
You can use hardware image bounds protection when either image robustness
feature is supported. Advertising robustness2 with its image flag disabled
must not hide the older supported feature. Software checks remain enabled
when neither feature is available.

The previous detection triggered a Mali shader compiler crash while compiling
texture loads through function parameters. The physical-material gallery
reproduced it on a Pixel 9 Pro running Android 17. With this patch, the same
gallery passes through Vulkan. The added unit test covers all nine combinations
of absent, disabled and enabled feature records.

The Dart build hook tracks the vendored source directory as an input. Rust's
root dependency file does not include patched dependency sources, so changes
here otherwise leave Flutter's cached native library unchanged.
