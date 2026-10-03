# Character Lab

You can run the native scene on macOS, Android or iOS with Flutter 3.47.5.
The moving biped uses imported skinning, fixed-step root motion, capsule collision,
generated navigation and foot IK. The second biped retargets the same pose onto
longer legs. Use Obstacle to update collision and navigation together.

Run `flutter run -d <device>` from this directory. The integration test exercises
native presentation, resizing, movement, pause/resume and surface cleanup.
See the character package qualification record for actual device results.
