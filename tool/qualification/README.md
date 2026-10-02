# Run Planet after device tests

If Planet ignores your taps, drags or trackpad gestures after a test, restore the
normal app from the workspace root:

```sh
python3 tool/qualification/geospatial_stories.py launch --preset tokyo --device macos --provider-config /path/to/private-provider.json
```

Use your connected device ID for Android or iOS. Add `--ios` for an iPhone and
`--flutter /path/to/flutter` if Flutter isn't on your PATH. Your existing signing
configuration still applies. The preset selects the atmosphere or cloud lab;
you can choose the city inside the app.

The command builds `lib/google_tiles_lab.dart` and leaves it running. It uses
Flutter's normal input binding. Device tests use an integration-test binding
that drops physical input by default, even though injected test gestures work.
Keeping that test app installed does not make it interactive.

The `run` command now restores the normal app after qualification, including
failed tests. It saves test evidence before restoring the app, then records the
launch result separately in `interactive-app.json` and `interactive-app.log`.
A successful launch does not certify gesture behavior or change the test result.
If restoration fails, the command exits with an error and you can retry with
`launch` once your device is available.

For a batch of tests, you can pass `--leave-test-app` between runs. Run `launch`
after the last one. If you invoke `flutter drive` directly, you also need to
restore the normal app yourself before handing the device back.

Keep physical input disabled during automated tests so an accidental touch
cannot alter their results. Check real input separately in the normal app:
switch cities, drag the scene, pinch on a phone and scroll on a trackpad. Watch
the camera move; an injected gesture test alone cannot verify this path.
