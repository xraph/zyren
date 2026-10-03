# Reality capture qualification

You can load real encoded LAS, LAZ and E57 fixtures, render streamed points and
perspective Gaussians in one native scene, filter classifications and apply section
planes. The app retains source streams across plugin reattachment and closes them after
the controller drains. The controls wrap on narrow windows. A green plane checks opaque occlusion.
Native scene presentation requires Metal on Apple platforms or Vulkan on Android.

Use Flutter 3.47.5 from this workspace. From this directory:

```sh
fvm flutter run --no-pub -d macos
fvm flutter test integration_test/capture_test.dart --no-pub -d <device-id>
```

For an iPad or iPhone connected over Wi-Fi, use the host driver:

```sh
fvm flutter drive --no-pub --publish-port \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/capture_test.dart -d <device-id>
```

Flutter 3.47.5's `test` command cannot publish the VM service port that wireless
iOS testing requires. `drive` accepts this option and runs the same suite.
You'll still need a valid signing profile before the app can launch.

The integration suite checks both perspective and orthographic native pixels,
source attributes and ordinals, streamed scene content, filter/section controls,
semantics, zero-readback presentation, plugin reattachment and cleanup. Test captures use readback only
in the separate pixel assertions. Interactive presentation uses a native surface.

The files in `assets` are byte-identical copies of the package's synthetic,
repository-licensed fixtures. Their source and generator are documented in
`../../test/fixtures/README.md`. Copy all four regenerated fixtures into `assets`
when updating them. No external dataset, credentials or network service is required.

## Shared live MCP

Start the host process from this directory:

```sh
fvm dart run tool/live_mcp.dart
# Grant classification filtering and undo for this process only:
fvm dart run tool/live_mcp.dart --allow-filter
```

The process uses `zyren_devtools` stdio MCP and `zyren_agents`. It creates an actual
native scene, exposes viewport and streamed point/Gaussian providers, and drains
resources on EOF. It opens no network listener. Mutations require host scopes,
expected revisions and idempotency keys; this host does not grant chunk retry.

Run the external JSON-RPC probe with an explicit SDK command and report path:

```sh
python3 tool/verify_mcp.py 'fvm dart run tool/live_mcp.dart' /tmp/reality-mcp.json
```

The probe checks discovery, native capabilities, queries, denied commands,
filter/undo, identical retries, stale revisions and EOF cleanup. Provider entries
must disappear when the scene detaches. `dart run` is the qualified desktop host;
the experimental standalone AOT executable failed native backend startup and is
not a supported launch command here.

Choose your own development team/profile in Xcode for signed iOS deployment.
No signing team is committed in this app.

See [the evidence record](../../qualification/2026-10-03.md) for tested devices and
the iPhone and iPad signing blocker. Device discovery alone does not establish qualification.
