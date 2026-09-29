# Native dependency patch

You can inspect the complete local change in
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
submission results. This patch does not alter Vulkan or Direct3D behavior.
