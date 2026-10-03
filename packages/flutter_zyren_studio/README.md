# Flutter Zyren Studio

You can add editor tools to an existing Studio workspace without rebuilding its
viewport or docking layout. Create a contribution host with your current scene,
commands, agents, asset resolver and viewport services, then register contributions
and adapt their panes into the workspace you already use.

```dart
final lease = host.register(StudioEditorContribution(
  id: 'project.tools',
  version: 1,
  attach: (context) {
    context.registerPanel(StudioEditorPanel(
      id: 'project.problems',
      title: 'Problems',
      icon: Icons.error_outline,
      builder: (_, _) => StudioEditorProblems(controller: host),
    ));
  },
));
await host.whenSettled;
// Remove the contribution, including its open UI and callbacks.
lease.dispose();
```

`StudioEditorHost` wraps your supplied viewport and calls `workspaceBuilder`
with the contributed pane descriptors. Convert those into your workspace's pane
type. Keep its existing panes, docking state, theme, agent panel and review
flows. The Studio example uses this adapter around `StudioWorkspace`.

```dart
StudioEditorHost(
  controller: host,
  viewport: nativeViewport,
  workspaceBuilder: (context, contributed, viewport) => buildWorkspace(
    viewport,
    contributed,
  ),
)
```

## Register editor surfaces

Each contribution receives a `StudioEditorContext` backed by the host's existing
`StudioScene`, `StudioCommands`, history, selection, asset scope, asset resolver,
viewport controller/snapshot and capabilities. `applyDocument` awaits the host's
authoring callback; `select` uses its permission-checked command service. Play
sessions stay separate from the authored document.

You can register these surfaces:

| Registration | Use |
| --- | --- |
| `registerPanel` | A pane the existing workspace can dock and hide |
| `registerInspector` | A conditional section appended to the selected-object inspector |
| `registerAssetKind` | A file extension and importer using the host's asset workflow |
| `registerCommand` | An enabled predicate, optional shortcut and handler |
| `registerCreationTool` | An enabled creation action |
| `registerOverlay` | Viewport UI with explicit pointer interaction |
| `registerValidator` | Document validation with bounded problem results |
| `registerPlayFactory` | A supported-document check and isolated session factory |

Every method returns a `Registration` and keeps it in the contribution's existing
`AttachmentScope`. Disposing the contribution removes its UI and callbacks.
Disposing a play-factory registration also closes its active session and retires
pending creation. A detached context cannot register more callbacks or apply a
document.

`StudioEditorInspectorSections`, `StudioEditorCreationTools`,
`StudioEditorAssetKinds` and `StudioEditorPlayControls` render those registered
surfaces. Controls wrap on narrow screens. The asset widget takes your file
chooser and invokes the registered importer with the selected URI.
`StudioEditorProblems` uses the shared `ZeroState` for missing validators,
validation failures and completed empty results, so an absent validator never
looks like a passed check.

Commands check enabled state at invocation. Shortcut conflicts fail registration,
including conflicts with the host's reserved shortcuts. Plain shortcuts decline
text-entry events before Flutter consumes them. Detaching a focused pane restores
focus to the viewport, and the host preserves viewport widget state as
contributions come and go.

## Runtime providers and cleanup

Pass a `StudioAgentExtension` through `runtimeExtension`, or use
`context.agentExtensionContext` during attachment. Both paths compose the existing
Studio extension context and its deferred scene binding. The scene host must
already provide the shared `AgentRegistryPlugin`.

For a provider factory tied to runtime dependencies, use
`context.useAgentProviderPlugin`. It installs the existing `AgentProviderPlugin`.
You can declare other runtime plugins through `context.usePlugin` during
contribution attachment. The package doesn't create another registry or grant
additional agent scopes.

`StudioEditorServices.installRuntimePlugins` receives the complete contributed
plugin graph. Combine it with your captured base plugins and apply it through
`SceneController.setPlugins`. Keep this callback tied to that controller's
lifetime, and await `host.whenSettled` to observe attachment failures. Runtime
contributions remain unavailable until the installer succeeds. Failed runtime
attachment retires the candidate contribution and its dependents, then restores
the remaining contributed graph.

`registerAll` sorts dependencies before attaching a batch and rejects missing
dependencies or cycles before attachment. If an attachment fails, the batch rolls
back. Removing a dependency retires its dependents first.

Call `await host.close()` before releasing the scene controller, commands or
agent registry. Cleanup drains registrations even when one cleanup callback
fails, and `whenSettled`/`close` reports those failures. Pending cleanup futures
are retired when they finish; the host retains at most 64 cleanup errors for
diagnostics. `lastError` records the most recent runtime or cleanup failure.

You can call `host.refresh()` when host availability, selection or document state
changes. It updates contributed widgets without invoking the host's `onChanged`
callback again.

## Checks

From this package directory:

```sh
fvm flutter test --no-pub test/contribution_test.dart test/host_regression_test.dart
fvm dart analyze .
```

The tests cover registration rollback, dependencies, shortcut conflicts, provider
attachment through shared scene services, play lifecycle, detach/re-attach,
viewport state, focus restoration and widths of 1280, 396 and 328 logical pixels.
The scene-service test uses a contract renderer. It does not qualify a native GPU
or a platform device.

The Studio example retains responsibility for its asset persistence,
collaboration, command review and ordinary editor regression tests.
