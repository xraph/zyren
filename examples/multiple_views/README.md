# Scene ownership examples

Run `flutter run -d macos` from this directory. The same app has generated
runners for iOS, Android, Windows and Linux; those runners still need device
qualification. No handwritten platform setup is needed for this example.

The shared scene uses two controllers and two independent cameras. Turn the mesh
to update both views. Move either camera to change only that view. Close the left
view, then turn the mesh again to verify the right renderer remains active.

`managed_mesh.dart` shows view-owned setup and cleanup. `borrowed_viewer.dart`
shows a controller that survives unmounting its viewport. All three examples
import their 3D API from `package:flutter_gpu3d/flutter_gpu3d.dart`.

Rendering uses the native GPU. The default entrypoint selects RGBA readback for
Flutter presentation. Use `lib/native_scene_demo.dart` for direct Metal views
on Apple platforms or Vulkan surfaces on Android.

You can compare texture filtering and wrapping with:

```sh
fvm flutter run -d macos -t lib/textured_scene_demo.dart
```

Use your Android device ID in place of `macos` to select the Vulkan presenter.
The demo starts with a 2x2 color image. Select Nearest, Linear, Repeat, Clamp or
Mirror to update its sampler. Tap PNG or JPEG to decode a bundled file on a CPU
isolate and replace the native texture. Failures keep the current image visible
and let you retry. Deform moves one vertex; Shift UV edits texture coordinates.
Reset restores both attributes on the same geometry. Each edit wakes the native
view and the displayed revision advances. Materials still render opaquely;
transparency remains pending.

See [image decoding](../../docs/design/gpu-resources.md#decode-image-files) for
the public API, supported formats and memory limits.
