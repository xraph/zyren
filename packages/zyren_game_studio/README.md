# Game authoring for Studio

You can add character, vehicle, camera, input, interaction, inventory, ability
and objective components through the existing Studio inspector. Edits use the
same validated commands and undo history as the agent tools.

Register `GameStudioContribution(createGameAuthoring()).contribution` with the
shared `StudioEditorHostController` for the component catalog. For level templates
and behavior tools, use `createGameDevelopmentAuthoring` and register
`GameLevelStudioContribution` with the same rule library. See [level authoring](doc/levels.md).
The Studio example registers the game development contributions by default.
Import `authoring.dart` or `catalog.dart` for document tools that do not use
Flutter widgets. Import `compiler.dart` for the Pipeline compiler and export.

The catalog uses the runtime component definitions. Vehicle wheels are edited
in pairs. Invalid dimensions, missing targets and dependencies produce issues
with node and field locations. An invalid required component prevents play and
export. Unknown component payloads remain saved until their codec is available.

Prefab components live inside `StudioPrefab.extensions`; instance changes use
`StudioNode.extensionOverrides`. Duplication remaps declared entity references.
Inherited values and local overrides remain distinct after saving and reopening.
Structural copying with another extension requires that extension's adapter.

`GameAuthoringAgent` requires `studio.edit`, the current document revision and a
request key. It calls the same authoring methods as the inspector. Register it
through the contribution lifetime so detaching the editor removes its tools.

The compiler resolves pinned assets through `PipelineAssetLibrary`, builds with
`PipelineBuildRuntime`, and exports a bundle containing the compiled recipe and
its assets. Runtime loading uses `GameLevelManager` and the exported resolver.
The compiler entrypoint does not construct a Flutter widget or a native world.

Automated checks cover persisted prefab copies, reference remapping, malformed
saved fields, repair commands, revision and permission rejection, undo, and
inspector layouts at desktop and 328 logical pixels. Native play and device
qualification have separate checks; an authoring test does not establish them.
