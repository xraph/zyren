# Smaller plugins lab

Run this fixture with Flutter 3.47.5 and the workspace dependencies resolved:

```sh
flutter run --no-pub -d macos
```

You get a native Metal viewport on macOS/iOS and Vulkan on Android. Use the
compact controls to switch the body material, apply a camera preset, rebuild
SMAA/dithering, play a quiet tone or display the review overlay. The width button
keeps the working viewport at 360 logical pixels so you can check wrapping.
Failures use the shared ZeroState; loading remains a separate state.

The audio session pauses on focus loss or duck requests. On Android it requests
transient game audio focus and abandons it when the view goes into the
background. On iOS it observes interruptions and removed audio routes through
AVAudioSession. A permanent focus loss or removed route requires another Play.
The agent's playback guard uses the same focus state. You still need to qualify
calls, headphones, Bluetooth and resume behavior on physical devices.

Platform references: [Android audio focus](https://developer.android.com/media/optimize/audio-focus),
[Apple interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)
and [Apple route changes](https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes).

## Checks

```sh
flutter test --no-pub test/audio_session_test.dart
flutter drive --no-pub --driver=test_driver/lab.dart \
  --target=integration_test/lab_test.dart -d macos
flutter build apk --debug --target-platform android-arm64 --no-pub
flutter build ios --debug --no-codesign --no-pub
```

The native integration check verifies presented scene/camera correlation,
source identity at the viewport center, configuration changes, stale frame
rejection, effects resources, overlay reporting, narrow layout and real audio
cursor progress through suspension. It does not establish human audibility.

For the live stdio MCP check, add `--dart-define=ZYREN_SMALLER_MCP=true` to the
integration command. The host prints a `ZYREN_SMALLER_BRIDGE_FILE` path containing
local bridge credentials. Keep that file private. In another terminal, run:

```sh
python3 tool/probe_mcp.py /path/from/host/zyren-smaller-native-bridge.json \
  /tmp/zyren-smaller-displayed-mcp.json
```

Set `DART` to the Dart executable from Flutter 3.47.5 if it is not on your PATH. After inspecting the displayed result,
create `zyren-smaller-native-bridge.done` beside the credentials file to let the
test finish. The probe uses the existing devtools MCP transport and saves no
credentials in its evidence. Do not attach an accessibility inspector during a
clean integration run: macOS can enable a semantics handle after the test records
its baseline, causing Flutter's teardown leak check to fail. Inspect the normal
app separately, or retain the visual run as evidence and rerun unattended.

Frame correlation uses a plugin registered after the effects plugin. It records
the scene and camera revisions before rendering, checks they remain unchanged
through completion, and joins the native frame ID to the controller's actual
presentation callback. A changed or missing snapshot remains unknown. This
fixture does not claim physical display scanout or GPU object visibility.

The capture manager and video exporter run in the package's headless examples
and native tests. Their isolated camera output does not include this app's
Flutter controls or overlays. GPU resources created by a different backend
cannot be copied into an isolated capture session.
