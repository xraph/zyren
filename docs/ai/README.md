# Connect your assistant to Zyren

You can ask an MCP assistant to inspect a running scene, explain a blank viewport,
check renderer support or summarize recent frame costs. The tools read your local
debug session. Your chosen assistant supplies the model.

## Start the workbench

From `examples/multiple_views`, run:

```sh
fvm flutter run -d macos -t lib/scene_workbench.dart --dart-define=ZYREN_AI_DX=true
```

Use `-d <device-id>` for Android. The debug console prints one `ZYREN_AI_DX` JSON
line with `endpoint` and `token`. Copy those values into your terminal:

```sh
export ZYREN_DEVTOOLS_ENDPOINT='http://127.0.0.1:PORT/call'
export ZYREN_DEVTOOLS_TOKEN='TOKEN_FROM_DEBUG_CONSOLE'
fvm dart run zyren_devtools:zyren inspect_scene
fvm dart run zyren_devtools:zyren diagnose_scene
fvm dart run zyren_devtools:zyren capture_frame_stats '{"limit":30}'
fvm dart run zyren_devtools:zyren export_report > zyren-report.json
```

The endpoint uses the device's loopback interface. For Android, forward its port
before connecting from your computer: `adb -s <device-id> forward tcp:PORT tcp:PORT`.
Remove that forwarding when done. Desktop tooling and the native macOS example
are verified; device forwarding still needs a separate device check.

The flag has no effect in profile or release builds. Restarting the app creates a
new token. The socket closes when the workbench is disposed. Do not commit debug
logs, tokens or reports containing private scene names and issue messages.

## Configure an MCP client

Use this entry in a client that supports stdio MCP. Replace all placeholders,
including the executable path, with values from your environment:

```json
{
  "mcpServers": {
    "zyren": {
      "command": "/absolute/path/to/dart",
      "args": ["/absolute/path/to/flutter-geospatial/packages/zyren_devtools/bin/zyren.dart", "mcp"],
      "env": {
        "ZYREN_DEVTOOLS_ENDPOINT": "http://127.0.0.1:PORT/call",
        "ZYREN_DEVTOOLS_TOKEN": "TOKEN_FROM_DEBUG_CONSOLE"
      }
    }
  }
}
```

Run `fvm flutter pub get` in this checkout first. Use the Dart executable from the
same Flutter SDK. The server implements [MCP 2025-11-25 stdio](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
and advertises seven read-only tools after initialization:

| Tool | Result |
| --- | --- |
| `inspect_scene` | Paginated hierarchy, local transforms, camera and revision |
| `inspect_object` | One object, its material summary and world matrix |
| `get_renderer_capabilities` | Reported backend features and enforced limits |
| `get_scene_issues` | Bounded host issue history, including startup errors |
| `capture_frame_stats` | Retained frames and measured CPU/GPU summaries |
| `diagnose_scene` | Visibility, camera, clip bounds and feature findings |
| `export_report` | Bounded scene, capabilities, diagnosis, issues and frames |

Try: "Use Zyren to explain why the scene is blank. Cite object IDs and measured
evidence. Then propose a Dart patch using the APIs in docs/ai/AGENT_GUIDE.md."

Or: "Inspect the renderer capabilities and last 30 frames. Explain which costs
we measured and which remain unknown before suggesting an optimization."

## Connect your own scene

The [compiled recipe](../../packages/zyren_devtools/example/inspection_recipe.dart)
creates a scene, camera, inspector and diagnostics instance. Attach its inspector
as a plugin before the engine starts. In Flutter, call `controller.use(inspector)`
and subscribe to `controller.issues` with `diagnostics.recordIssue`.

Import `package:zyren_devtools/io.dart` only in the host that needs networking.
After an explicit debug opt-in, call `DevtoolsServer.start(diagnostics)`. Keep the
returned server, show its connection details in your local debug console and
await `server.close()` during host cleanup. Cancel the issue subscription too.
The host owns this lifecycle. The pure Dart diagnostics library starts no socket.

## Read the evidence correctly

Results use `schemaVersion: 1` and `packageVersion: 0.1.0`. A session ID includes
the inspector attachment. Do not carry IDs between sessions. Scene pages default
to 100 nodes and allow up to 1000. Pass `expectedRevision` with `nextOffset` to
reject pages collected across scene changes. Inspections stop at 10000 nodes with
`sceneTooLarge`; they never silently diagnose a partial scene.

Bounds outside a clip plane establish exclusion. Bounds overlap does not prove
pixel visibility. The doctor does not check occlusion or rendered pixel contrast.
An explicit `aspect` overrides the live viewport or last recorded frame ratio.

`capture_frame_stats` reads history. It does not request a render, screenshot or
new profiling interval. CPU times are microseconds spent on Dart construction and
encoding. GPU time and resident bytes stay null when unavailable. Readback and
upload bytes do not represent total GPU memory. An average GPU time uses only the
frames with a measurement; `gpuMeasuredFrames` tells you how many.

Reports cap nodes at 1000 and frames at 120 and retain pagination metadata. They
omit asset bytes, exception objects and source URIs. Names and issue text remain
application data and may contain private information. Review a report before
sharing it. Reports are diagnostic evidence, not asset-complete scene replays.

The current tools do not edit scenes, execute generated code, call a hosted model
or provide a Flutter DevTools extension. Use your assistant's normal file-editing
workflow for a reviewable Dart patch, then run analysis and tests.
