# zyren_devtools

Inspect a scene without importing the native renderer or Flutter.

```dart
final inspector = SceneDevtoolsPlugin(historyLimit: 120);
controller.use(inspector);
await controller.ready;
final sceneInfo = inspector.snapshot();
final object = inspector.objectFor(sceneInfo.nodes.first.id);
final recentFrames = inspector.frames;
```

Snapshots copy hierarchy, local transforms, visibility and mesh information.
IDs stay stable within one inspector instance. `objectFor` resolves only objects
still in the attached scene, so an old snapshot cannot retain a removed mesh.
You can inspect inherited visibility separately from a node's own flag.

`frames` returns a copy of the bounded frame history. GPU time and resident bytes
remain null when the backend cannot report them. Resource payload counters are
not total GPU memory, and this package does not expose a native allocation list.
Detaching clears frame history and disables scene queries.

Dependent plugins can request the exported `sceneDevtools` service key after
declaring `zyren.devtools` as a dependency. Flutter hosts can use the controller's
sampled `frameStats` stream to refresh their diagnostics UI.

## AI diagnostics and local tools

`SceneDiagnostics(inspector)` exposes a versioned JSON inspection API, conservative
blank-scene checks and bounded diagnostic reports. Call `recordIssue` with host
issues, including initialization failures. No model is required by the package.

The optional `package:zyren_devtools/io.dart` library provides a token-protected
loopback bridge and a stdio MCP server. The `zyren` executable can inspect the
same session from your terminal or MCP client. Networking starts only when your
host explicitly calls `DevtoolsServer.start`; close the server during cleanup.

See [AI setup](../../docs/ai/README.md) for workbench commands, MCP configuration,
result limits and a compiled authoring recipe. See the
[agent guide](../../docs/ai/AGENT_GUIDE.md) for current API conventions.
