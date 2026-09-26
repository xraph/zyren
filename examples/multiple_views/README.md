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

Rendering uses the native GPU. These examples explicitly select RGBA readback for
Flutter presentation while shared GPU textures are being implemented.
