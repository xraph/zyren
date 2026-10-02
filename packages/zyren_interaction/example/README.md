# Native object interaction

Run this macOS example with the repository-pinned Flutter SDK:

```sh
cd packages/zyren_interaction/example
fvm flutter run -d macos
```

You can hover and drag either box, undo the drag, remove the selected object and
reset the scene. The camera stays fixed while object capture owns the drag.
Controls wrap at narrow widths. Empty and renderer failure states use ZeroState.
The renderer uses native Metal on macOS. The supplied runner targets macOS;
Android and iOS presentation still need their own runner and device checks.

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
selection, retry behavior and stale rejection through the real CLI MCP session.
The test deletes its credential file after the probe completes. Evidence omits
credentials. This opt-in test grants access only to its procedural demo scene.
