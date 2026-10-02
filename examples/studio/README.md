# Zyren Studio example

Run the editor with the workspace's pinned Flutter SDK:

```sh
cd examples/studio
fvm flutter run -d macos
```

You can select a box in the viewport or inspector, move/rotate/scale it with the
native gizmo, and undo or redo the transform. `X +0.25` offers a precise local edit.
Save writes `studio-scene.json` in the application's support directory. Hover
Save to see its path. Reload reads that file and asks before discarding unsaved
edits. The first launch opens an assembly fixture when no save exists.

Preview camera runs the existing timeline service. Stop preview restores your
working camera. Save, reload and editing are disabled while the preview is active.
The inspector moves below the viewport at narrow widths.

The host registers Studio and viewport providers in the shared agent registry.
`StudioEditorState.agents` exposes the in-process interface. Agent mutations are
denied by default. Pass `agentScopes: {'studio.select', 'studio.edit'}` when your
host grants those actions. Registration and retry history end with the editor
session. You can opt into the existing authenticated loopback bridge in a debug build:

```sh
fvm flutter run -d macos --dart-define=ZYREN_AI_DX=true --dart-define=ZYREN_AGENT_EDIT=true
```

The console reports a `ZYREN_STUDIO_AGENTS` endpoint and session token. Set those
as `ZYREN_DEVTOOLS_ENDPOINT` and `ZYREN_DEVTOOLS_TOKEN` for your MCP client, then
run `ZYREN_AGENT_TOOLS=1 fvm dart run zyren_devtools:zyren mcp` from the workspace.
Without `ZYREN_AGENT_EDIT`, inspection remains available and mutations are denied.
The bridge closes when its editor session ends. The host also attempts to register
the shared diagnostics provider; incompatible schemas appear in
`state.screen.agentProviderGaps`, while the original diagnostic tools remain
available through the bridge.

The first document format supports groups and diffuse boxes. It preserves source
record IDs and engineering annotations, but the example does not yet expose
annotation authoring, asset import, prefabs, materials or animation authoring.
The generated runner targets macOS. Android and iOS require their own runners and
live qualification; there is no browser fallback.

```sh
fvm flutter test --no-pub
fvm flutter test --no-pub -d macos integration_test/studio_test.dart
```

The widget tests use a substituted viewport and do not establish GPU behavior.
Native integration evidence and remaining checks live in
[the Studio plan](../../plans/zyren-plugins/studio.md).
