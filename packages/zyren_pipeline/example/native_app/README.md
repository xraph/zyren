# Pipeline Lab

You can inspect a prepared mesh, compare its original geometry and reload it from
a persistent offline cache. The fixture has 512 original triangles and 128 LOD
triangles. Both use the same UASTC texture and stable `part:grid` source identity.

Generate the fixture from the workspace root after building the pinned worker:

```sh
fvm dart run packages/zyren_pipeline/example/prepare_fixture.dart
```

Run this app from its directory:

```sh
fvm flutter run --no-pub -d macos
fvm flutter test --no-pub integration_test/pipeline_test.dart -d macos
fvm flutter test --no-pub integration_test/pipeline_test.dart -d <device-id>
fvm flutter build ios --debug --no-pub --no-codesign
```

Use your own device ID for mobile tests. Configure your development team in the
iOS Runner project before installing a signed build. Wait until other
qualification jobs release the device. The app requires native Metal view presentation on
macOS/iOS or native Vulkan presentation on Android. There is no browser fallback.

Evict cache removes the bundled source from the registered runtime cache and the
local file cache. Your current mesh remains usable. Reload then shows the shared
empty state; Restore bundle writes and loads the fixture again. The disk directory
is private to this app's temporary storage. Normal startup restores the packaged
fixture when it is missing. It does not fetch network content.

The shared viewport provider returns source provenance and CPU geometry hits.
It records accepted presentation IDs. Captured scene/camera revisions are not
available from the controller event, so frame correlation and rendered pixel
visibility remain unknown. The integration test checks this boundary explicitly.


For a wireless iOS device, use the integration driver. The pinned Flutter SDK's
`test` command disables port publication, which wireless debugging requires.

```sh
fvm flutter drive --no-pub --publish-port \
  --driver=test_driver/pipeline_test.dart \
  --target=integration_test/pipeline_test.dart -d <device-id>
```

You'll need a development profile for `dev.zyren.zyrenPipelineLab` that includes
your device. An unsigned build cannot establish on-device presentation. The
[mobile check record](qualification/2026-10-03.md) separates the Pixel result from
the iPad signing blocker.
