# Native shared scene

Run this macOS example from its directory:

```sh
fvm flutter run -d macos --no-pub
```

Alice and Bob share a source-keyed box through one durable authority. Alice's
outbox uses HTTP. Bob uses WebSocket requests and invalidations. The authority
and Alice's outbox survive app restarts in the app container's Application
Support directory. Credentials are random for each launch and stay in memory.

Move Alice, go offline, queue another Alice move, then move Bob. Reconnecting
shows the competing transform. Choose the exact edit to keep. Undo Alice uses
a conditional inverse and reports a conflict if another edit changed its field.
Follow Alice applies her leased camera to Bob's viewport. Orbit Alice updates
that shared camera; touching Bob's viewport stops following.

The compact layout puts the viewports beside each other on desktop and stacks
them below 650 logical points. The app uses Metal native views on macOS. It has
no browser renderer. This example ships a macOS host; other platform hosts are
not qualified by its test.

## Native and MCP checks

From this directory, start the test:

```sh
fvm flutter test integration_test/shared_scene_test.dart -d macos --no-pub \
  --dart-define=ZYREN_EXTERNAL_MCP_CHECK=true > /tmp/scene-native.log 2>&1
```

While it runs, launch the probe from the workspace root, supplying your pinned
Dart executable:

```sh
python3 packages/zyren_collaboration/example/native_app/tool/native_mcp_probe.py \
  --log /tmp/scene-native.log --dart /path/to/pinned/dart \
  --evidence /tmp/scene-native-mcp.json
```

The probe starts the existing devtools CLI. It discovers providers, reads native
renderer and presented-frame data, picks the source object, changes visibility,
checks exact retry and stale rejection, and undoes the change. It also inspects
presence and the durable outbox. Credentials are passed only to the child
process and are excluded from evidence.

The viewport pick reports CPU triangle geometry. Rendered-pixel visibility and
exact scene/camera correlation with the presented frame remain unknown because
the native frame sample does not capture those revisions.

For a shared dependency check independent of concurrent work, run
`python3 packages/zyren_collaboration/tool/committed_bridge_config.py` from the
workspace root. It exports `zyren_agents` and `zyren_devtools` from `828955b`
into a temporary directory and returns a package map, CLI path and source commit.
Pass that map through Flutter's global `--packages=...` option. Give the probe
its matching `--package-config`, `--cli` and `--shared-source-revision` arguments.
No shared source file is changed by this procedure.
