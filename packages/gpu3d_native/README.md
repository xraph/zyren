# gpu3d_native

Render gpu3d scenes through native Metal, Vulkan or Direct3D 12. Dart build hooks
compile the bundled Rust crate. You need Rust and the platform toolchain.

`NativeRenderer` implements the existing scene renderer. `NativeBackend` accepts
immutable `FrameSubmission` values through the advanced backend contract. Both
use the same native worker and ABI; neither requires a Flutter engine.

```sh
fvm dart run example/offscreen.dart
RUN_NATIVE_GPU=1 fvm dart test
```

The example renders a red box and prints the centre pixel. GPU tests require a
compatible device. In PowerShell, set `$env:RUN_NATIVE_GPU = '1'` before running
`fvm dart test`.

Shared-texture adapters are not implemented yet. Surface requests fail with
`presentationUnavailable`; the implemented path returns explicit RGBA8 sRGB
readback. Close the backend when you finish so its worker and GPU resources are
released.
