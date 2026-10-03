# Native object interaction

Run this native example with the repository-pinned Flutter SDK:

```sh
cd packages/zyren_interaction/example
fvm flutter run -d macos
```

You can hover and drag either box, undo the drag, remove the selected object and
reset the scene. Drag empty space to orbit; a second touch transfers control to
navigation. Tab focuses objects and Enter selects. Edit note opens a projected
Flutter text field whose focus suspends scene gestures.

Controls wrap at narrow widths. Empty and renderer failure states use ZeroState.
Runners are supplied for macOS, Android 10 or newer, iOS and Windows. macOS Metal and Pixel
Vulkan have native integration evidence; a generated runner alone does not qualify
its platform. See the interaction plan for current iOS and Windows limits.

Widget tests substitute the viewport to check layout without claiming native GPU
presentation. Dart tests exercise real CPU triangle picking and scene tools.

## Native agent check

The example registers viewport, interaction and existing devtools providers with
host scopes for selection and undoable transforms. It starts no transport by
default. The integration test can start the existing authenticated loopback
bridge and wait for a separate CLI MCP process:

```sh
fvm flutter test --no-pub -d macos integration_test/native_interaction_test.dart \
  --dart-define=ZYREN_EXTERNAL_MCP_CHECK=true > /tmp/zyren-interaction-native-test.log 2>&1
```

While that test runs, invoke `tool/native_mcp_probe.py` in another terminal. Pass
`--log /tmp/zyren-interaction-native-test.log`, `--dart` with your Dart executable
path, and `--evidence` with an output JSON path. The probe reads the temporary
credential file announced by the test, then verifies discovery, a rich hit,
selection, retry behavior, stale rejection, normalized coordinates, bounds, job
handles and resource subscriptions through the real CLI MCP session.
The test deletes its credential file after the probe completes. Evidence omits
credentials. This opt-in test grants access only to its procedural demo scene.

For a wirelessly attached iOS device, Flutter 3.47.5 integration tests need the
published VM service used by the driver:

```sh
fvm flutter drive --no-pub --publish-port -d DEVICE_ID \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/native_interaction_test.dart
```
