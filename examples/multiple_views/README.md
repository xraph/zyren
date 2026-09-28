# Scene ownership examples

Run `fvm flutter run -d macos -t lib/scene_workbench.dart` for the plugin
workbench. You can select assembly parts, edit local transforms, undo and redo,
measure two surface points and scrub an exploded view. Use your Android device
ID for native Vulkan presentation. The inspector moves below the canvas on a
narrow screen and scrolls independently.

The workbench uses `zyren_tools`, `zyren_devtools` and `zyren_timeline` through
their public APIs. See [the checkpoint](https://xraph.com/docs/zyren/reference/scene-workbench-checkpoint)
for verification and remaining features.

Run `flutter run -d macos` from this directory. The same app has generated
runners for iOS, Android, Windows and Linux; those runners still need device
qualification. No handwritten platform setup is needed for this example.

The shared scene uses two controllers and two independent cameras. Turn the mesh
to update both views. Move either camera to change only that view. Close the left
view, then turn the mesh again to verify the right renderer remains active.

`managed_mesh.dart` shows view-owned setup and cleanup. `borrowed_viewer.dart`
shows a controller that survives unmounting its viewport. All three examples
import their 3D API from `package:flutter_zyren/flutter_zyren.dart`.

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
Reset restores both attributes on the same geometry. The plane uses uint16
indices and fixed float32 attributes. Each edit wakes the native
view and the displayed revision advances. Materials still render opaquely;
transparency remains pending.

See [image decoding](https://xraph.com/docs/zyren/reference/design/gpu-resources#decode-image-files) for
the public API, supported formats and memory limits.

You can inspect face culling and lighting with:

```sh
fvm flutter run -d macos -t lib/material_side_demo.dart
```

Front, Back and Both select the triangle faces to render. View back moves the
camera behind the triangle; Mirror changes its parent's scale. Lit and Unlit
switch shading. The light follows the camera so you can check back-face normals.
The same entrypoint selects native Vulkan presentation on Android.
