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
The demo uses one immutable 2x2 color image and updates its material sampler when
you select Nearest, Linear, Repeat, Clamp or Mirror. It renders opaque pixels;
image decoding and transparency are still pending.
